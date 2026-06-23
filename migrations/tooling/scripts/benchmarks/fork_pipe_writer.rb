#!/usr/bin/env ruby
# frozen_string_literal: true

# Mimics the proposed "step-level parallelism" parent: N forked producers each
# run a whole step, Oj-encode their produced rows and stream them over a pipe to
# the parent. The parent runs one decoder thread per fork (`Oj.load`, object
# mode, same OJ_SETTINGS as the real `Worker`) feeding a SINGLE writer thread
# that is the sole caller of `Connection#insert`.
#
# The payload is a realistic wide user row carrying real OBJECTS (Time, IPAddr,
# booleans, nils) serialized through Oj object mode — that is what makes the
# encode/decode cost representative. The parent writer applies the real
# `format_*` helpers before binding (in production those run in the worker, so
# loading the single writer with them here is conservative).
#
# Measures real aggregate throughput through the single writer, with and without
# `gvl_release_threshold = 0`, against a pure-serial inline baseline.
#
# Run from the core gem:
#   cd migrations/core
#   bundle exec ruby ../tooling/scripts/benchmarks/fork_pipe_writer.rb

core_lib = File.expand_path("../../../core/lib", __dir__)
$LOAD_PATH.unshift(core_lib)
require "migrations-core"
require "oj"
require "ipaddr"
require "tempfile"

Connection = Migrations::Database::Connection
DB = Migrations::Database

TOTAL_ROWS = Integer(ENV.fetch("TOTAL_ROWS", "2000000"))
FORK_COUNT = Integer(ENV.fetch("FORK_COUNT", "4"))
BATCH_SIZE = Integer(ENV.fetch("BATCH_SIZE", "1000")) # rows per Oj message
ITERATIONS = Integer(ENV.fetch("ITERATIONS", "2"))

# IMPORTANT: write DBs to REAL disk, never tmpfs (/tmp here is RAM-backed — many
# multi-writer shard DBs there exhaust memory). Default to a real-disk scratch dir.
DB_DIR = ENV.fetch("DB_DIR", "/var/tmp/fork_pipe_bench")
require "fileutils"
FileUtils.mkdir_p(DB_DIR)
# Bound in-flight memory: at most this many batches sit in a writer's queue.
# (producer_count * 100 batches * BATCH_SIZE rows could buffer millions of rows.)
QUEUE_BATCHES = Integer(ENV.fetch("QUEUE_BATCHES", "16"))

OJ_SETTINGS = { mode: :object, class_cache: true, symbol_keys: true }.freeze

# Codec for the worker->parent wire (decode is the parent bottleneck). The
# payload is post-format PRIMITIVES, so object mode is unnecessary here.
require "json"
# When set, the per-row SQL (identical across a step) is sent ONCE per batch
# instead of repeated in every [sql, params] pair — roughly halves the payload.
FACTOR_SQL = ENV.fetch("FACTOR_SQL", "0") == "1"
CODEC = ENV.fetch("CODEC", "oj_object")
ENCODE, DECODE =
  case CODEC
  when "oj_object"
    [->(o) { Oj.dump(o, OJ_SETTINGS) }, ->(s) { Oj.load(s, OJ_SETTINGS) }]
  when "oj_strict"
    [->(o) { Oj.dump(o, mode: :strict) }, ->(s) { Oj.load(s, mode: :strict) }]
  when "json"
    [->(o) { JSON.generate(o) }, ->(s) { JSON.parse(s) }]
  else
    raise "unknown CODEC #{CODEC}"
  end

COLUMNS = %w[
  original_id
  active
  admin
  approved
  approved_at
  approved_by_id
  avatar_type
  created_at
  date_of_birth
  first_seen_at
  flair_group_id
  group_locked_trust_level
  ip_address
  last_seen_at
  locale
  manual_locked_trust_level
  moderator
  name
  original_username
  primary_group_id
  registration_ip_address
  silenced_till
  staged
  title
  trust_level
  uploaded_avatar_id
  username
  views
].freeze
SQL = "INSERT INTO users (#{COLUMNS.join(", ")}) VALUES (#{(["?"] * COLUMNS.size).join(", ")})"

BASE_TIME = Time.now.utc

# Raw row carrying real objects (Time, IPAddr, booleans, nils), in COLUMNS order.
def build_raw_row(id)
  t = BASE_TIME + id
  [
    id,
    true,
    false,
    true,
    t,
    nil,
    1,
    t,
    t,
    t,
    nil,
    nil,
    IPAddr.new("1.2.3.4"),
    t,
    "en",
    nil,
    false,
    "John Doe #{id}",
    "john_#{id}",
    nil,
    IPAddr.new("10.0.0.#{id % 256}"),
    nil,
    false,
    nil,
    1,
    nil,
    "john#{id}",
    0,
  ]
end

# Per-column formatters mirroring the generated `create` (datetime/date/boolean/
# ip get converted, everything else passes through).
FORMATTERS =
  begin
    f = Array.new(COLUMNS.size) { :itself.to_proc }
    dt = ->(v) { DB.format_datetime(v) }
    COLUMNS.each_with_index do |name, i|
      f[i] = case name
      when "approved_at", "created_at", "first_seen_at", "last_seen_at", "silenced_till"
        dt
      when "date_of_birth"
        ->(v) { DB.format_date(v) }
      when "active", "admin", "approved", "moderator", "staged"
        ->(v) { DB.format_boolean(v) }
      when "ip_address", "registration_ip_address"
        ->(v) { DB.format_ip_address(v) }
      else
        :itself.to_proc
      end
    end
    f.freeze
  end

def format_row(raw)
  raw.each_with_index.map { |value, i| FORMATTERS[i].call(value) }
end

def prepare_db
  tempfile = Tempfile.new(%w[fork_pipe .db], DB_DIR)
  path = tempfile.path
  tempfile.close
  tempfile.unlink

  db = Connection.open_database(path:)
  db.execute("CREATE TABLE users (#{COLUMNS.map { |c| "#{c} TEXT" }.join(", ")})")
  db.close
  path
end

def cleanup_db(path)
  [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

# One forked producer: like a worker running a serial step, it builds rows from
# objects and applies the converter `format_*` helpers HERE (as `create` does),
# capturing `[sql, formatted_params]` pairs — exactly what `OfflineConnection`
# stores. It ships `[statements, stats]` as length-prefixed Oj object-mode blobs
# (length framing is robust under backpressure, unlike streaming when flooded).
def fork_producer(write_io, first_id, rows)
  fork do
    produced = 0
    while produced < rows
      n = [BATCH_SIZE, rows - produced].min
      stats = { progress: n, warning_count: 0, error_count: 0 }
      payload =
        if FACTOR_SQL
          params = Array.new(n) { |i| format_row(build_raw_row(first_id + produced + i)) }
          ENCODE.call([SQL, params, stats])
        else
          statements =
            Array.new(n) { |i| [SQL, format_row(build_raw_row(first_id + produced + i))] }
          ENCODE.call([statements, stats])
        end
      write_io.write([payload.bytesize].pack("N"))
      write_io.write(payload)
      produced += n
    end
    write_io.close
    exit!(0)
  end
end

# One writer group: forks `producer_count` producers over `rows` ids starting at
# `first_id`, and a single writer thread (fed by one decoder thread per producer)
# inserts everything into `path`. This is the single-writer parent, reused as a
# building block for the hybrid arm.
def produce_and_write(path, producer_count, first_id, rows, gvl_threshold)
  per = rows / producer_count
  remainder = rows % producer_count

  read_ios = []
  pids = []
  next_id = first_id
  producer_count.times do |i|
    n = per + (i.zero? ? remainder : 0)
    r, w = IO.pipe
    pids << fork_producer(w, next_id, n)
    w.close
    read_ios << r
    next_id += n
  end

  connection = Connection.new(path:, gvl_release_threshold: gvl_threshold)
  output_queue = SizedQueue.new(QUEUE_BATCHES)

  writer =
    Thread.new do
      Thread.current.name = "writer"
      if FACTOR_SQL
        while (item = output_queue.pop)
          sql, rows_params = item
          rows_params.each { |params| connection.insert(sql, params) }
        end
      else
        while (statements = output_queue.pop)
          statements.each { |stmt_sql, params| connection.insert(stmt_sql, params) }
        end
      end
      connection.commit_transaction
    end

  decoders =
    read_ios.map.with_index do |io, i|
      Thread.new do
        Thread.current.name = "decoder_#{i}"
        while (header = io.read(4))
          payload = io.read(header.unpack1("N"))
          if FACTOR_SQL
            sql, rows_params, _stats = DECODE.call(payload)
            output_queue.push([sql, rows_params])
          else
            statements, _stats = DECODE.call(payload)
            output_queue.push(statements)
          end
        end
      ensure
        io.close
      end
    end

  decoders.each(&:join)
  output_queue.close
  writer.join
  connection.close
  pids.each { |pid| Process.waitpid(pid) }
end

# Single writer: all FORK_COUNT producers -> one parent writer -> one DB.
def run_fork_pipe(path, gvl_threshold)
  produce_and_write(path, FORK_COUNT, 1, TOTAL_ROWS, gvl_threshold)
end

def make_shard
  tempfile = Tempfile.new(%w[shard .db], DB_DIR)
  shard_path = tempfile.path
  tempfile.close
  tempfile.unlink
  db = Connection.open_database(path: shard_path)
  db.execute("CREATE TABLE users (#{COLUMNS.map { |c| "#{c} TEXT" }.join(", ")})")
  db.close
  shard_path
end

def merge_shards(final_path, shard_paths)
  db = Connection.open_database(path: final_path)
  shard_paths.each do |sp|
    db.execute("ATTACH DATABASE ? AS shard", sp)
    db.execute("INSERT INTO users SELECT * FROM shard.users")
    db.execute("DETACH DATABASE shard")
  end
  db.close
  shard_paths.each { |p| cleanup_db(p) }
end

# Multi-writer (P=N): each fork writes its OWN db directly (no pipe, no Oj —
# build+format+insert), then the parent merges the shards. Timing includes merge.
def run_multi_writer(final_path, gvl_threshold)
  per = TOTAL_ROWS / FORK_COUNT
  remainder = TOTAL_ROWS % FORK_COUNT
  shard_paths = Array.new(FORK_COUNT) { make_shard }

  next_id = 1
  pids =
    FORK_COUNT.times.map do |i|
      n = per + (i.zero? ? remainder : 0)
      first = next_id
      next_id += n
      fork do
        conn = Connection.new(path: shard_paths[i], gvl_release_threshold: gvl_threshold)
        (first...(first + n)).each { |id| conn.insert(SQL, format_row(build_raw_row(id))) }
        conn.commit_transaction
        conn.close
        exit!(0)
      end
    end
  pids.each { |pid| Process.waitpid(pid) }

  merge_shards(final_path, shard_paths)
end

# Hybrid: WRITER_COUNT single-writer parent PROCESSES, each fed by FORK_COUNT/P
# producers and owning its own db, then merge the P shards. Timing includes merge.
def run_hybrid(final_path, gvl_threshold, writer_count)
  rows_per_group = TOTAL_ROWS / writer_count
  remainder = TOTAL_ROWS % writer_count
  producers_per = [FORK_COUNT / writer_count, 1].max
  shard_paths = Array.new(writer_count) { make_shard }

  next_id = 1
  pids =
    writer_count.times.map do |g|
      n = rows_per_group + (g.zero? ? remainder : 0)
      first = next_id
      next_id += n
      fork do
        produce_and_write(shard_paths[g], producers_per, first, n, gvl_threshold)
        exit!(0)
      end
    end
  pids.each { |pid| Process.waitpid(pid) }

  merge_shards(final_path, shard_paths)
end

def run_inline_serial(path)
  connection = Connection.new(path:, gvl_release_threshold: 0)
  (1..TOTAL_ROWS).each { |id| connection.insert(SQL, format_row(build_raw_row(id))) }
  connection.commit_transaction
  connection.close
end

def verify(path)
  db = Connection.open_database(path:)
  count = db.query_single_splat("SELECT COUNT(*) FROM users")
  db.close
  warn "  !! expected #{TOTAL_ROWS} rows, got #{count}" if count != TOTAL_ROWS
end

def bench(label)
  times = []
  ITERATIONS.times do
    path = prepare_db
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield path
    times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    verify(path)
    cleanup_db(path)
  end
  best = times.min
  printf(
    "  %-34s best %7.3fs  (%s rows/s)\n",
    label,
    best,
    (TOTAL_ROWS / best).round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse,
  )
  best
end

GVL = Integer(ENV.fetch("GVL", "1000"))
HYBRID_WRITERS = Integer(ENV.fetch("HYBRID_WRITERS", "2"))

puts "",
     "Single vs multi vs hybrid writer (fork + pipe + Oj/json)",
     "  rows=#{TOTAL_ROWS}  forks=#{FORK_COUNT}  batch=#{BATCH_SIZE}  cols=#{COLUMNS.size}  codec=#{CODEC}  factor_sql=#{FACTOR_SQL}  gvl=#{GVL}  iters=#{ITERATIONS}  ruby=#{RUBY_VERSION}",
     ""

bench("serial inline (1 process)") { |path| run_inline_serial(path) }
bench("single writer (#{FORK_COUNT} forks)") { |path| run_fork_pipe(path, GVL) }
bench("multi-writer (#{FORK_COUNT} dbs)+merge") { |path| run_multi_writer(path, GVL) }
bench("hybrid (#{HYBRID_WRITERS}w/#{FORK_COUNT}f)+merge") do |path|
  run_hybrid(path, GVL, HYBRID_WRITERS)
end
puts ""
