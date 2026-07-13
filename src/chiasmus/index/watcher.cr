require "file_utils"
require "wait_group"
require "sync-map"
require "./file_discovery"

module Chiasmus
  module Index
    # Polling-based filesystem watcher.
    #
    # Spawn a fiber, call `run`, and it periodically checks
    # file modification times via FastFind's concurrent directory walker.
    # Changed files are yielded to the callback.
    #
    # Call `stop` to end the polling loop.
    class Watcher
      @root : String
      @interval : Time::Span
      @callback : String ->
      @timestamps = Sync::Map(String, Time).new
      @running = false
      @done = Channel(Bool).new(1)

      def initialize(@root, interval : Time::Span | Float64 = 1.0, &@callback : String ->)
        @interval = interval.is_a?(Time::Span) ? interval : interval.seconds
      end

      # Start polling in the current fiber.
      def run
        @running = true
        scan_initial

        while @running
          changes = scan_changes
          changes.each { |path| @callback.call(path) }
          sleep(@interval)
        end
      rescue
      ensure
        @done.close rescue nil
      end

      # Stop the watcher. Returns immediately.
      def stop : Bool
        @running = false
        true
      end

      # Block until the watcher fiber has stopped.
      def wait
        @done.receive?
      rescue Channel::ClosedError
      end

      # Return relative paths of all watched files.
      def watched_files : Array(String)
        @timestamps.keys.sort!
      end

      private def scan_initial
        each_file_entry(@root) do |relative, mtime|
          @timestamps.store(relative, mtime)
        end
      end

      private def scan_changes : Array(String)
        changed = [] of String
        seen = Set(String).new

        each_file_entry(@root) do |relative, mtime|
          seen << relative
          prev, found = @timestamps.load(relative)

          if found && prev != mtime
            changed << relative
          elsif !found
            changed << relative
          end
          @timestamps.store(relative, mtime)
        end

        @timestamps.each_key do |key|
          unless seen.includes?(key)
            @timestamps.delete(key)
            changed << key
          end
        end

        changed
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
