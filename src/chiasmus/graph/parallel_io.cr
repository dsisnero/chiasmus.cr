require "./types"
require "../utils/bounded_work"

module Chiasmus
  module Graph
    module FileIO
      extend self

      DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT
      MAX_FILE_SIZE          = 10 * 1024 * 1024

      record SourceReadResult,
        files : Array(SourceFile),
        warnings : Array(String)

      private record SourceReadOutcome,
        file : SourceFile? = nil,
        warning : String? = nil
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

      # Read source files while retaining non-fatal per-path failures for MCP
      # callers. File-size validation happens before File.read so an oversized
      # input cannot monopolize extraction memory or the MCP transport.
      def read_source_files_with_warnings(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT) : SourceReadResult
        outcomes = Utils::BoundedWork.map_ordered(file_paths, resolve_max_concurrent(max_concurrent)) do |path|
          begin
            if File.info(path).size > MAX_FILE_SIZE
              SourceReadOutcome.new(warning: "Skipped #{path}: file exceeds #{MAX_FILE_SIZE} bytes")
            else
              run_before_read_hook(path)
              SourceReadOutcome.new(file: SourceFile.new(path: path, content: File.read(path)))
            end
          rescue ex
            SourceReadOutcome.new(warning: "Skipped #{path}: #{ex.message || ex.class.name}")
          end
        end

        files = [] of SourceFile
        warnings = [] of String
        outcomes.each do |outcome|
          next unless outcome
          if file = outcome.file
            files << file
          end
          if warning = outcome.warning
            warnings << warning
          end
        end
        SourceReadResult.new(files: files, warnings: warnings)
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
