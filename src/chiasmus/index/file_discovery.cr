require "./fast_find"
require "../graph/parser"

module Chiasmus
  module Index
    # One source of file-inclusion truth for initial indexing and polling.
    # Git repositories include tracked plus untracked, non-ignored files;
    # non-Git directories fall back to FastFind.
    module FileDiscovery
      extend self
      MAX_FILE_SIZE = 500_000_i64

      def paths(root : String) : Array(String)
        (git_paths(root) || walker_paths(root)).select do |path|
          info = File.info?(path)
          relative = Path.new(path).relative_to(root)
          visible = relative.parts.none?(&.starts_with?('.'))
          visible && info && info.size <= MAX_FILE_SIZE && Graph::Parser.language_for_file(path)
        end
      end

      private def git_paths(root : String) : Array(String)?
        output = IO::Memory.new
        status = Process.run(
          "git",
          ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
          output: output,
          error: Process::Redirect::Close,
        )
        return nil unless status.success?

        output.to_s.split('\0').compact_map do |relative|
          next if relative.empty?
          path = File.expand_path(relative, root)
          path if File.file?(path)
        end
      rescue
        nil
      end

      private def walker_paths(root : String) : Array(String)
        config = FastFind::Config.new
        config.ignore_hidden = true
        config.follow_symlinks = false

        paths = [] of String
        queue = FastFind::Walker.new([root], config).walk
        while entry = queue.receive?
          paths << entry.path.to_s if entry.file?
        end
        paths
      end
    end
  end
end
