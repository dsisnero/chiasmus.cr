require "wait_group"
require "./watcher"

module Chiasmus
  module Index
    # Runs watcher change sets one at a time and merges the deltas that pile up
    # while a batch is running.
    #
    # The polling watcher yields a `ChangeSet` every interval. Applying one can
    # take longer than that interval (per-file extraction plus cache writes), so
    # spawning a fiber per callback lets batches overlap: concurrent SQLite
    # writers and the same tree re-extracted by several fibers. This keeps at
    # most one batch in flight and folds everything that arrived meanwhile into
    # the next one.
    #
    # Callbacks are also coordinated with shutdown: new batches are rejected
    # once `#close_and_drain` starts, and work already queued is awaited
    # (bounded) before the caches it touches are closed.
    class WatchBatchQueue
      DEFAULT_DRAIN_TIMEOUT = 5.seconds

      def initialize(@timeout : Time::Span = DEFAULT_DRAIN_TIMEOUT, &@handler : ChangeSet ->)
        @lock = Mutex.new
        @wg = WaitGroup.new
        @pending = nil.as(ChangeSet?)
        @running = false
        @closing = false
      end

      # Queue `changes` and return immediately. Starts the drain fiber when no
      # batch is running; otherwise the delta is merged into the pending batch.
      def submit(changes : ChangeSet) : Nil
        start = @lock.synchronize do
          if @closing
            false
          else
            @pending = @pending.try(&.merge(changes)) || changes
            if @running
              false
            else
              @running = true
              @wg.add
              true
            end
          end
        end

        spawn { drain } if start
      end

      def closing? : Bool
        @lock.synchronize { @closing }
      end

      # Stop accepting work and wait for pending and in-flight batches. Never
      # blocks longer than the configured timeout.
      # Returns false when a handler outlives the deadline. The caller must
      # leave resources used by that handler open in that case.
      def close_and_drain : Bool
        @lock.synchronize { @closing = true }

        drained = Channel(Nil).new(1)
        spawn do
          @wg.wait
          drained.send(nil) rescue nil
        end

        select
        when drained.receive
          true
        when timeout(@timeout)
          STDERR.puts "[Chiasmus] warning: watcher batch still running after #{@timeout}"
          false
        end
      end

      private def drain : Nil
        loop do
          batch = @lock.synchronize do
            if pending = @pending
              @pending = nil
              pending
            else
              @running = false
              nil
            end
          end
          break unless batch

          begin
            @handler.call(batch)
          rescue ex
            # One failing batch must not kill the drain fiber and strand every
            # later change.
            STDERR.puts "[Chiasmus] watcher batch failed: #{ex.message}"
          end
        end
      ensure
        @wg.done
      end
    end
  end
end
