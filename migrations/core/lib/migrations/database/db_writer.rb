# frozen_string_literal: true

module Migrations
  module Database
    # Owns the `Connection` of the IntermediateDB for a whole conversion run.
    #
    # By default writes go straight to the `Connection` on the caller's thread
    # ("direct mode") — there is only ever one producer at a time (the main
    # thread for serial steps, the collector thread for parallel steps), so no
    # serialization is needed and the queue/thread overhead is avoided.
    #
    # When a section runs genuinely concurrent producers, wrap it in
    # `#concurrent`: for the duration of the block writes are funnelled through
    # a single writer thread via a `SizedQueue`, so `Connection#insert` (which
    # is not thread-safe) still has exactly one caller.
    #
    # `insert`, `flush` and `close` are no-ops in forked child processes; workers
    # write through an `OfflineConnection` instead.
    class DbWriter
      QUEUE_SIZE = 10_000

      class ClosedError < StandardError
      end

      class WriteError < StandardError
      end

      def initialize(path:)
        @owner_pid = Process.pid
        @mutex = Mutex.new
        @queue = nil
        @thread = nil
        @park_request = nil
        @error = nil
        @closed = false
        @concurrent = false

        # Hook registration order matters here: `ForkManager` runs hooks in
        # registration order, so the writer thread parks (in concurrent mode)
        # before the connection's own before-fork hook closes the database, and
        # the connection is reopened before the writer resumes.
        @pause_hook = ForkManager.before_fork { pause }

        begin
          # NOTE: `gvl_release_threshold: 0` (writer holds the GVL per insert)
          # only pays off when the writer is the bottleneck (cheap, write-bound
          # rows). For realistic wide rows the parent's Oj-decoder threads are
          # the bottleneck, and a greedy writer starves them — measured ~19%
          # slower at the sweet-spot fork count. So leave the extralite default.
          @connection = Connection.new(path:)
          @resume_hook = ForkManager.after_fork_parent { resume }
        rescue StandardError
          @connection&.close
          ForkManager.remove_before_fork(@pause_hook)
          ForkManager.remove_after_fork_parent(@resume_hook) if @resume_hook
          raise
        end
      end

      # Runs the block with writes funnelled through a single writer thread, so
      # multiple producer threads may call `insert` concurrently. All producers
      # must have finished (be joined) before the block returns; on exit the
      # queue is drained and the writer thread stopped, and the writer goes back
      # to direct mode.
      def concurrent
        return yield if Process.pid != @owner_pid

        @mutex.synchronize do
          check_open!
          check_error!
          raise ThreadError, "already in a concurrent section" if @concurrent
          @queue = SizedQueue.new(QUEUE_SIZE)
          @concurrent = true
        end
        @thread = start_writer_thread(@queue)

        begin
          yield
        ensure
          drain_and_stop
        end
      end

      def insert(sql, parameters = [])
        return if Process.pid != @owner_pid

        if @concurrent
          @mutex.synchronize do
            check_open!
            check_error!
          end
          @queue.push([sql, parameters])
        else
          # Direct mode: single producer, so the bare flag reads are safe and a
          # failed statement raises immediately, mirroring the old inline path.
          # The error is also stored so later calls keep failing fast.
          check_open!
          check_error!
          begin
            @connection.insert(sql, parameters)
          rescue StandardError => e
            @error ||= e
            check_error!
          end
        end
        nil
      end

      # Barrier: returns once all previously enqueued statements have been
      # executed (not necessarily committed). A no-op in direct mode, where
      # every `insert` has already executed synchronously.
      def flush
        return if Process.pid != @owner_pid
        if Thread.current == @thread
          raise ThreadError, "`flush` cannot be called from the writer thread"
        end

        @mutex.synchronize do
          check_open!
          check_error!
          return unless @concurrent
          raise ThreadError, "`flush` cannot be called while paused for a fork" if @park_request
        end

        request = FlushRequest.new(Queue.new)
        @queue.push(request)
        request.done.pop

        @mutex.synchronize { check_error! }
        nil
      end

      def close
        return if Process.pid != @owner_pid

        @mutex.synchronize do
          return if @closed
          @closed = true

          # unpark the writer thread in case `close` happens while paused
          @park_request&.resumed&.push(true)
          @park_request = nil
        end

        if @thread
          @queue&.close
          @thread.join
          @thread = nil
        end

        @connection.close

        ForkManager.remove_before_fork(@pause_hook)
        ForkManager.remove_after_fork_parent(@resume_hook)

        @mutex.synchronize { check_error! }
        nil
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      private

      FlushRequest = Struct.new(:done)
      ParkRequest = Struct.new(:acknowledged, :resumed)

      def drain_and_stop
        # All concurrent producers have finished, so no further pushes happen;
        # closing the queue lets the writer drain the remainder and exit.
        @queue.close
        @thread.join
        @thread = nil

        @mutex.synchronize do
          @concurrent = false
          @queue = nil
        end
        @mutex.synchronize { check_error! }
      end

      def start_writer_thread(queue)
        Thread.new do
          Thread.current.name = "db_writer"

          # `pop` returns the remaining items and then `nil` once the queue has
          # been closed, so the writer always drains before the thread exits.
          while (item = queue.pop)
            case item
            when ParkRequest
              park_until_resumed(item)
            when FlushRequest
              item.done.push(true)
            else
              execute(item)
            end
          end
        end
      end

      def execute(item)
        # After a failed statement the writer stops writing but keeps consuming,
        # so producers never block on a full queue; the stored error is raised
        # on their next `insert`, `flush` or `close` call. Only this thread
        # assigns `@error` in concurrent mode, so the bare read is safe;
        # producers read it under `@mutex`.
        return if @error

        sql, parameters = item
        @connection.insert(sql, parameters)
      rescue StandardError => e
        @mutex.synchronize { @error ||= e }
      end

      # Rendezvous used by the before-fork hook while in concurrent mode: pushes
      # a sentinel behind all pending statements and blocks until the writer
      # thread has executed them and parked outside any `Connection` call.
      # Producers may keep enqueueing while paused; only consumption stops.
      #
      # A no-op in direct mode: there is no writer thread, and the connection's
      # own before-fork hook closes the database while the single producer is
      # provably not mid-insert (it is the thread driving the fork).
      #
      # The whole rendezvous is per-request — each `ParkRequest` carries its own
      # acknowledge and resume queues — so a resume can never be attributed to
      # the wrong park, no matter how closely fork windows follow each other.
      def pause
        request = nil

        @mutex.synchronize do
          return if @closed
          return unless @concurrent
          request = ParkRequest.new(Queue.new, Queue.new)
          @park_request = request
        end

        @queue.push(request)
        request.acknowledged.pop
      end

      def resume
        request = @mutex.synchronize { @park_request.tap { @park_request = nil } }
        request&.resumed&.push(true)
      end

      def park_until_resumed(request)
        request.acknowledged.push(true)
        request.resumed.pop
      end

      # Both expect `@mutex` to be held by the caller, except on the direct-mode
      # `insert` path where the single producer reads the flags unlocked.
      def check_open!
        raise ClosedError, "`DbWriter` is closed" if @closed
      end

      def check_error!
        raise WriteError, "Writing to the database failed", cause: @error if @error
      end
    end
  end
end
