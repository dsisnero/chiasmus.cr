require "./types"
require "../utils/bounded_work"

module Chiasmus
  module Graph
    module FileIO
      extend self

      DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT
      @@before_read_hook = nil.as((String -> Nil)?)
      @@before_read_hook_mutex = Mutex.new
      @@default_max_concurrent_for_test = nil.as(Int32?)
      @@default_max_concurrent_for_test_mutex = Mutex.new

      # Read files concurrently via spawn + Channel.
      # Returns only successfully-read files; failed reads are silently skipped.
      # Use `read_source_files_or_raise` for callers that need error propagation.
      def read_source_files_parallel(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT) : Array(SourceFile)
        read_source_files_parallel(file_paths, resolve_max_concurrent(max_concurrent)) do |path|
          run_before_read_hook(path)
          File.read(path)
        end
      end

      def read_source_files_parallel(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String) : Array(SourceFile)
        Utils::BoundedWork
          .map_ordered(file_paths, max_concurrent) do |path|
            SourceFile.new(path: path, content: reader.call(path))
          end
          .compact_map(&.itself)
          .reject(&.content.empty?)
      end

      # Read files concurrently, raising on first failure.
      def read_source_files_or_raise(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT) : Array(SourceFile)
        read_source_files_or_raise(file_paths, resolve_max_concurrent(max_concurrent)) do |path|
          run_before_read_hook(path)
          File.read(path)
        end
      end

      def read_source_files_or_raise(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String) : Array(SourceFile)
        Utils::BoundedWork.map_ordered_or_raise(file_paths, max_concurrent) do |path|
          begin
            SourceFile.new(path: path, content: reader.call(path))
          rescue ex
            raise "Failed to read #{path}: #{ex.message}"
          end
        end
      end

      private def run_before_read_hook(path : String) : Nil
        hook = @@before_read_hook_mutex.synchronize { @@before_read_hook }
        hook.try(&.call(path))
      end

      private def resolve_max_concurrent(max_concurrent : Int32) : Int32
        override = @@default_max_concurrent_for_test_mutex.synchronize { @@default_max_concurrent_for_test }
        Math.max(1, override || max_concurrent)
      end

      def set_before_read_hook_for_test(&block : String ->) : Nil
        @@before_read_hook_mutex.synchronize do
          @@before_read_hook = block
        end
      end

      def clear_before_read_hook_for_test : Nil
        @@before_read_hook_mutex.synchronize do
          @@before_read_hook = nil
        end
      end

      def default_max_concurrent_for_test=(value : Int32) : Nil
        @@default_max_concurrent_for_test_mutex.synchronize do
          @@default_max_concurrent_for_test = value
        end
      end

      def clear_default_max_concurrent_for_test : Nil
        @@default_max_concurrent_for_test_mutex.synchronize do
          @@default_max_concurrent_for_test = nil
        end
      end
    end
  end
end
