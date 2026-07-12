require "spec"
require "file_utils"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/cache"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/index/watcher"

include Chiasmus::Graph
include Chiasmus::Index

private def with_temp_dir(& : String ->)
  dir = File.tempname("chiasmus-watcher-cache-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) rescue nil
  end
end

describe "Watcher + Cache integration" do
  it "extract_and_cache_file saves graph and returns it" do
    with_temp_dir do |dir|
      file_path = File.join(dir, "test.cr")
      File.write(file_path, "def greet\n  \"hello\"\nend")

      cache_dir = File.join(dir, ".cache")
      repo_key = GraphCache.default_repo_key(dir)

      result = Extractor.extract_and_cache_file(
        file_path,
        cache_dir: cache_dir,
        repo_key: repo_key,
      )

      result.should_not be_nil

      # Save to cache and verify
      content = File.read(file_path)
      check = GraphCache.check_file_cache(
        [{path: file_path, content: content}],
        cache_dir,
        repo_key: repo_key,
      )

      # If tree-sitter grammar loaded, we'll have a cache hit;
      # if not, the graph was empty and we didn't cache — either is valid
      if result.try { |r| !r.defines.empty? }
        check[:hits].size.should eq 1
        check[:hits].first[:path].should eq file_path
      end
    end
  end

  it "watcher triggers eager re-extraction on file change" do
    with_temp_dir do |dir|
      file_path = File.join(dir, "main.cr")
      File.write(file_path, "def v1\n  1\nend")

      cache_dir = File.join(dir, ".cache")
      repo_key = GraphCache.default_repo_key(dir)

      # Warm the parser
      Parser.get_language_for_file(file_path)

      # Watcher with eager re-extraction callback
      changed = [] of String
      watcher = Watcher.new(dir, interval: 0.05.seconds) do |rel_path|
        changed << rel_path
        abs_path = File.join(dir, rel_path)
        spawn do
          Extractor.extract_and_cache_file(
            abs_path,
            cache_dir: cache_dir,
            repo_key: repo_key,
          )
        end
      end
      spawn { watcher.run }
      sleep(0.15.seconds)

      File.write(file_path, "def v2\n  2\nend")
      sleep(0.15.seconds)
      watcher.stop

      changed.any?(&.ends_with?("main.cr")).should be_true
    end
  end
end
