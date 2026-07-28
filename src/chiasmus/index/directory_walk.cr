require "dir-walk"

module Chiasmus
  module Index
    # Shared adapter for dir-walk. Hidden entries are excluded, symlinks are
    # not followed, and .gitignore files do not alter a scan's results.
    module DirectoryWalk
      extend self

      def files(root : String, max_depth : Int32 = 0) : Array(String)
        paths = Channel(String).new(256)
        result = Channel(Array(String)).new(1)

        spawn do
          collected = [] of String
          while path = paths.receive?
            collected << path
          end
          result.send(collected)
        end

        begin
          Dir::Walk.walk(config(max_depth), root) do |path, entry, error|
            next if error || entry.nil? || !entry.file?
            paths.send(path)
          end
        ensure
          paths.close
        end

        result.receive
      end

      private def config(max_depth : Int32) : Dir::Walk::Config
        ignore_options = Dir::Walk::Ignore::IgnoreOptions.new(
          hidden: true,
          ignore: false,
          parents: false,
          git_ignore: false,
          git_exclude: false,
          require_git: false,
        )

        Dir::Walk::Config.new(
          follow: false,
          max_depth: max_depth,
          ignore: true,
          ignore_opts: ignore_options,
        )
      end
    end
  end
end
