require "./types"

module Chiasmus
  module Graph
    module FileIO
      extend self

      private record ReadResult,
        index : Int32,
        source : SourceFile? = nil,
        error : String? = nil

      # Read files concurrently via spawn + Channel.
      # Returns only successfully-read files; failed reads are silently skipped.
      # Use `read_source_files_or_raise` for callers that need error propagation.
      def read_source_files_parallel(file_paths : Array(String)) : Array(SourceFile)
        return [] of SourceFile if file_paths.empty?

        chan = Channel({Int32, SourceFile}).new(file_paths.size)

        file_paths.each_with_index do |path, idx|
          spawn do
            content = File.read(path)
            chan.send({idx, SourceFile.new(path: path, content: content)})
          rescue ex
            chan.send({idx, SourceFile.new(path: path, content: "")})
          end
        end

        results = Array(SourceFile?).new(file_paths.size, nil)
        file_paths.size.times do
          idx, src = chan.receive
          results[idx] = src
        end

        results.compact_map(&.itself).reject(&.content.empty?)
      end

      # Read files concurrently, raising on first failure.
      def read_source_files_or_raise(file_paths : Array(String)) : Array(SourceFile)
        return [] of SourceFile if file_paths.empty?

        chan = Channel(ReadResult).new(file_paths.size)

        file_paths.each_with_index do |path, idx|
          spawn do
            content = File.read(path)
            chan.send(ReadResult.new(index: idx, source: SourceFile.new(path: path, content: content)))
          rescue ex
            chan.send(ReadResult.new(index: idx, error: "Failed to read #{path}: #{ex.message}"))
          end
        end

        results = Array(SourceFile?).new(file_paths.size, nil)
        first_error = nil.as(String?)

        file_paths.size.times do
          entry = chan.receive
          if error = entry.error
            first_error ||= error
          elsif source = entry.source
            results[entry.index] = source
          end
        end

        raise first_error if first_error

        results.compact_map(&.itself)
      end
    end
  end
end
