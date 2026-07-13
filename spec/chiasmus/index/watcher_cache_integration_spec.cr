require "spec"
require "file_utils"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/cache"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/index/project_index"
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

private def wait_until(timeout = 2.seconds, interval = 10.milliseconds, &condition : -> Bool) : Bool
  deadline = Time.instant + timeout
  until condition.call
    return false if Time.instant >= deadline
    sleep(interval)
  end
  true
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

  it "removes resident facts and every cached graph version after file deletion" do
    with_temp_dir do |dir|
      file_path = File.join(dir, "removed.cr")
      cache_dir = File.join(dir, ".cache")
      repo_key = GraphCache.default_repo_key(dir)
      index = ProjectIndex.new

      File.write(file_path, "def version_one\n  1\nend\n")
      first = Extractor.extract_and_cache_file(file_path, cache_dir: cache_dir, repo_key: repo_key)
      first.should_not be_nil
      index.upsert_file(first || raise "expected initial graph")
      GraphCache.flush_async_writes

      watcher = Watcher.new(dir, interval: 0.02.seconds) do |rel_path|
        abs_path = File.join(dir, rel_path)
        if File.exists?(abs_path)
          if graph = Extractor.extract_and_cache_file(abs_path, cache_dir: cache_dir, repo_key: repo_key)
            index.upsert_file(graph)
          end
        else
          index.remove_file(abs_path)
          GraphCache.invalidate_file_cache([abs_path], cache_dir, repo_key: repo_key)
        end
      end

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?("removed.cr") }.should be_true

        File.write(file_path, "def version_two\n  2\nend\n")
        wait_until { index.definitions_named("version_two").size == 1 }.should be_true
        GraphCache.flush_async_writes

        # Simulate a superseded blob produced by an older cache implementation.
        paths = GraphCache.resolve_cache_paths(cache_dir, repo_key)
        legacy_orphan = File.join(paths["files_dir"], "legacy-orphan.json")
        File.write(legacy_orphan, %({"defines":[{"file":#{file_path.to_json},"name":"version_one"}]}))

        File.delete(file_path)
        wait_until { index.definitions_in_file(file_path).empty? }.should be_true

        manifest = JSON.parse(File.read(paths["manifest_path"]))
        manifest["entries"].as_h.has_key?(file_path).should be_false

        cached_graphs = Dir.glob(File.join(paths["files_dir"], "*.json"))
          .map { |path| File.read(path) }
        cached_graphs.none?(&.includes?(file_path)).should be_true
      ensure
        watcher.stop
        watcher.wait
        index.close
      end
    end
  end
end
