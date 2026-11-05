require "file_utils"
require "wait_group"
require "sync-map"
require "./file_discovery"

module Chiasmus
  module Index
    record ChangeSet,
      added : Array(String),
      modified : Array(String),
      deleted : Array(String) do
      def empty? : Bool
        added.empty? && modified.empty? && deleted.empty?
      end

      def changed : Array(String)
        added + modified
      end

      def size : Int32
        added.size + modified.size + deleted.size
      end

      # Fold a later poll delta into this one, keeping the net effect:
      # deleting then re-creating a path is an add, and adding then deleting a
      # path before either batch ran is a delete (it never entered the index).
      # Used to coalesce change sets that arrive while a batch is running.
      def merge(other : ChangeSet) : ChangeSet
        added = self.added.to_set
        modified = self.modified.to_set
        deleted = self.deleted.to_set

        other.added.each do |path|
          deleted.delete(path)
          modified.delete(path)
          added << path
        end

        other.modified.each do |path|
          next if added.includes?(path)
          if deleted.delete(path)
            added << path
          else
            modified << path
          end
        end

        other.deleted.each do |path|
          modified.delete(path)
          added.delete(path)
          deleted << path
        end

        ChangeSet.new(added.to_a.sort!, modified.to_a.sort!, deleted.to_a.sort!)
      end
    end

    # Polling-based filesystem watcher.
    #
    # Spawn a fiber, call `run`, and it periodically checks
    # file modification times via dir-walk's concurrent directory walker.
    # Changed files are yielded to the callback.
    #
    # Call `stop` to end the polling loop.
    class Watcher
      # A poll that sees the whole watched set vanish is far more likely to be a
      # transient filesystem view (a volume briefly unmounting, an exFAT/Fskit
      # hiccup) than a real `rm -rf`. Require this many consecutive empty polls
      # before reporting every tracked file as deleted.
      FULL_DELETION_CONFIRMATIONS = 2

      @root : String
      @interval : Time::Span
      @callback : ChangeSet ->
      @timestamps = Sync::Map(String, Time).new
      @running = false
      @stop_requested = Atomic(Bool).new(false)
      @stop_channel = Channel(Nil).new(1)
      @empty_scans = 0
      @done = Channel(Bool).new(1)

      def initialize(@root, interval : Time::Span | Float64 = 1.0, &@callback : ChangeSet ->)
        @interval = interval.is_a?(Time::Span) ? interval : interval.seconds
      end

      # Start polling in the current fiber.
      def run
        # `stop` may be called before this fiber gets scheduled (for example a
        # signal during startup). Honour that instead of resurrecting the loop.
        return if @stop_requested.get

        @running = true
        scan_initial

        until @stop_requested.get
          changes = scan_changes
          @callback.call(changes) unless changes.empty?
          break unless wait_for_next_poll
        end
      rescue
      ensure
        @running = false
        @done.close rescue nil
      end

      # Stop the watcher. Returns immediately.
      def stop : Bool
        @stop_requested.set(true)
        @running = false
        # Wake a fiber parked in wait_for_next_poll so it does not have to burn
        # a whole interval before noticing.
        select
        when @stop_channel.send(nil)
        else
        end
        true
      end

      # Wait for the watcher fiber to stop. A deadline lets a shutting-down
      # stdio server exit even if a filesystem scan never returns.
      def wait(deadline : Time::Span? = nil) : Bool
        if span = deadline
          select
          when @done.receive?
            true
          when timeout(span)
            false
          end
        else
          @done.receive?
          true
        end
      end

      # Return relative paths of all watched files.
      def watched_files : Array(String)
        @timestamps.keys.sort!
      end

      # Block until the next poll is due. Returns false when a stop was
      # requested, so shutdown does not wait out the whole interval.
      private def wait_for_next_poll : Bool
        select
        when @stop_channel.receive
          false
        when timeout(@interval)
          true
        end
      end

      private def scan_initial
        each_file_entry(@root) do |relative, mtime|
          @timestamps.store(relative, mtime)
        end
      end

      private def scan_changes : ChangeSet
        entries = [] of Tuple(String, Time)
        each_file_entry(@root) { |relative, mtime| entries << {relative, mtime} }

        if entries.empty? && !@timestamps.empty?
          @empty_scans += 1
          if @empty_scans < FULL_DELETION_CONFIRMATIONS
            # Suspected transient empty view: report nothing and leave
            # `@timestamps` untouched so files that come back are not treated
            # as a delete followed by a re-add.
            return ChangeSet.new([] of String, [] of String, [] of String)
          end
        else
          @empty_scans = 0
        end

        added = [] of String
        modified = [] of String
        deleted = [] of String
        seen = Set(String).new

        entries.each do |(relative, mtime)|
          seen << relative
          prev, found = @timestamps.load(relative)

          if found && prev != mtime
            modified << relative
          elsif !found
            added << relative
          end
          @timestamps.store(relative, mtime)
        end

        @timestamps.each_key do |key|
          unless seen.includes?(key)
            @timestamps.delete(key)
            deleted << key
          end
        end

        ChangeSet.new(added.sort!, modified.sort!, deleted.sort!)
      end

      # Use the same Git-aware discovery rules as initial project indexing.
      # Yields (relative_path, modification_time) for each supported source file.
      private def each_file_entry(root : String, & : String, Time ->)
        FileDiscovery.paths(root).each do |path|
          if md = File.info?(path)
            relative = Path.new(path).relative_to(root).to_s
            yield relative, md.modification_time
          end
        end
      end
    end
  end
end
