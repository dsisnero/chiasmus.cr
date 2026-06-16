require "./types"

module Chiasmus
  module Graph
    module FileIO
      extend self

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

        chan = Channel({Int32, SourceFile}).new(file_paths.size)
        err_chan = Channel(String).new(1)

        file_paths.each_with_index do |path, idx|
          spawn do
            content = File.read(path)
            chan.send({idx, SourceFile.new(path: path, content: content)})
          rescue ex
            err_chan.send("Failed to read #{path}: #{ex.message}")
          end
        end

        results = Array(SourceFile?).new(file_paths.size, nil)
        received = 0

        loop do
          break if received >= file_paths.size
          select
          when entry = chan.receive?
            break unless entry
            idx, src = entry
            results[idx] = src
            received += 1
          when err_msg = err_chan.receive?
            raise err_msg if err_msg
          end
        end

        results.compact_map(&.itself)
      end
    end
  end
end
