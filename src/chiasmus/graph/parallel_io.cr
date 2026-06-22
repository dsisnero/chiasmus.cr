require "./types"
require "../utils/bounded_work"

module Chiasmus
  module Graph
    module FileIO
      extend self

      DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT

      # Read files concurrently via spawn + Channel.
      # Returns only successfully-read files; failed reads are silently skipped.
      # Use `read_source_files_or_raise` for callers that need error propagation.
      def read_source_files_parallel(file_paths : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT) : Array(SourceFile)
        read_source_files_parallel(file_paths, max_concurrent) { |path| File.read(path) }
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
        read_source_files_or_raise(file_paths, max_concurrent) { |path| File.read(path) }
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
    end
  end
end
