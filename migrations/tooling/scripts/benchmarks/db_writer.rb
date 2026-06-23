#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the two IntermediateDB write paths:
#
#   * "inline"    - the old serial path: the main thread calls
#                   `Connection#insert` directly.
#   * "db_writer" - the new run-level path: the main thread enqueues onto
#                   `DbWriter`, a single writer thread drains the queue and is
#                   the sole caller of `Connection#insert`.
#
# Both paths share the same `Connection`, so the difference is exactly the
# queue + writer-thread + mutex layer this branch adds. Close is included in
# the timing because `DbWriter#close` drains the queue and joins the thread.
#
# Run from the core gem so the right gems (extralite) are on the bundle:
#
#   cd migrations/core
#   bundle exec ruby ../tooling/scripts/benchmarks/db_writer.rb

core_lib = File.expand_path("../../../core/lib", __dir__)
$LOAD_PATH.unshift(core_lib)
require "migrations-core"

require "tempfile"

ROW_COUNT = Integer(ENV.fetch("ROW_COUNT", "2000000"))
ITERATIONS = Integer(ENV.fetch("ITERATIONS", "3"))

SQL_TABLE = <<~SQL
  CREATE TABLE users (
    id          INTEGER,
    name        TEXT,
    email       TEXT,
    created_at  DATETIME
  )
SQL
SQL_INSERT = "INSERT INTO users (id, name, email, created_at) VALUES (?, ?, ?, ?)"
USER = [1, "John", "john@example.com", "2023-12-29T11:10:04Z"]

Connection = Migrations::Database::Connection
DbWriter = Migrations::Database::DbWriter

def with_fresh_db
  tempfile = Tempfile.new(%w[db_writer_bench .db])
  path = tempfile.path
  tempfile.close
  tempfile.unlink

  db = Connection.open_database(path:)
  db.execute(SQL_TABLE)
  db.close

  yield path
ensure
  File.delete(path) if path && File.exist?(path)
  ["#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

def time
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# Models the per-row work a real converter step does before each insert
# (reading/transforming a source row). On MRI this Ruby work can overlap with
# the writer thread's SQLite C call (extralite releases the GVL there), so it
# is the variable that decides whether the queue pays for itself.
WORK_LOOPS = Integer(ENV.fetch("WORK_LOOPS", "0"))

def producer_work
  return USER if WORK_LOOPS.zero?
  acc = 0
  WORK_LOOPS.times { |i| acc += i }
  [acc % 1000, "John", "john@example.com", "2023-12-29T11:10:04Z"]
end

def run_inline(path)
  conn = Connection.new(path:)
  ROW_COUNT.times { conn.insert(SQL_INSERT, producer_work) }
  conn.commit_transaction
  conn.close
end

def run_db_writer(path)
  writer = DbWriter.new(path:)
  ROW_COUNT.times { writer.insert(SQL_INSERT, producer_work) }
  writer.close
end

# Concurrent section: several producer threads enqueue while one writer thread
# drains. Models the future "concurrent steps" case the queue exists for.
PRODUCER_COUNT = Integer(ENV.fetch("PRODUCER_COUNT", "4"))

def run_db_writer_concurrent(path)
  writer = DbWriter.new(path:)
  base = ROW_COUNT / PRODUCER_COUNT
  writer.concurrent do
    PRODUCER_COUNT
      .times
      .map do |i|
        rows = base + (i.zero? ? ROW_COUNT % PRODUCER_COUNT : 0)
        Thread.new { rows.times { writer.insert(SQL_INSERT, producer_work) } }
      end
      .each(&:join)
  end
  writer.close
end

def verify(path)
  db = Connection.open_database(path:)
  count = db.query_single_splat("SELECT COUNT(*) FROM users")
  db.close
  warn "  !! expected #{ROW_COUNT} rows, got #{count}" if count != ROW_COUNT
end

def bench(label)
  times = []
  ITERATIONS.times do
    with_fresh_db do |path|
      times << time { yield path }
      verify(path)
    end
  end
  best = times.min
  rate = (ROW_COUNT / best).round
  printf(
    "  %-12s best %7.3fs  avg %7.3fs  (%s rows/s)\n",
    label,
    best,
    times.sum / times.size,
    rate.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse,
  )
  best
end

puts "",
     "DbWriter write benchmark",
     "  rows=#{ROW_COUNT}  iterations=#{ITERATIONS}  ruby=#{RUBY_VERSION}",
     ""

inline = bench("inline") { |path| run_inline(path) }
direct = bench("writer/direct") { |path| run_db_writer(path) }
conc = bench("writer/conc") { |path| run_db_writer_concurrent(path) }

printf("\n  writer/direct vs inline: %+.1f%% wall time\n", (direct - inline) / inline * 100)
printf(
  "  writer/conc   vs inline: %+.1f%% wall time  (%d producers)\n\n",
  (conc - inline) / inline * 100,
  PRODUCER_COUNT,
)
