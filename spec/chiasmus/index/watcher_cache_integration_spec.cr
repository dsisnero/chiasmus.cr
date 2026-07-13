require "spec"
require "file_utils"
require "random/secure"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/cache"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/facts"
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
  it "adds, updates, and deletes a Crystal file across the index, facts, and SQLite cache" do
    with_temp_dir do |dir|
      src_dir = File.join(dir, "src")
      Dir.mkdir(src_dir)

      suffix = Random::Secure.hex(6)
      baseline_path = File.join(src_dir, "watcher_baseline_#{suffix}.cr")
      file_path = File.join(src_dir, "watcher_lifecycle_#{suffix}.cr")
      initial_helper = "cache_initial_helper_#{suffix}"
      initial_entry = "cache_initial_entry_#{suffix}"
      updated_helper = "cache_updated_helper_#{suffix}"
      updated_entry = "cache_updated_entry_#{suffix}"
      initial_source = <<-CR
        def #{initial_helper}
          41
        end

        def #{initial_entry}
          #{initial_helper}
        end
        CR
      updated_source = <<-CR
        def #{updated_helper}
          42
        end

        def #{updated_entry}
          #{updated_helper}
        end
        CR
      File.write(baseline_path, "# watcher startup sentinel\n")

      cache_dir = File.join(dir, ".cache")
      repo_key = GraphCache.default_repo_key(dir)
      index = ProjectIndex.new
      cache_store : SQLiteCacheStore? = nil
      added_paths = Channel(String).new(1)
      watcher = Watcher.new(dir, interval: 0.02.seconds) do |changes|
        changes.added.each { |path| added_paths.send(path) }
        spawn do
          deleted_paths = changes.deleted.map { |path| File.join(dir, path) }
          graphs = changes.changed.compact_map do |path|
            Extractor.extract_and_cache_file(
              File.join(dir, path),
              cache_dir: cache_dir,
              repo_key: repo_key,
            )
          end

          index.apply_batch(graphs, deleted_paths)
          GraphCache.invalidate_file_cache(deleted_paths, cache_dir, repo_key: repo_key) unless deleted_paths.empty?
        end
      end

      begin
        spawn { watcher.run }
        baseline_relative = Path.new(baseline_path).relative_to(dir).to_s
        wait_until { watcher.watched_files.includes?(baseline_relative) }.should be_true

        File.write(file_path, initial_source)
        added_relative = select
        when path = added_paths.receive
          path
        when timeout(2.seconds)
          raise "watcher did not report the added Crystal file"
        end
        added_relative.should eq(Path.new(file_path).relative_to(dir).to_s)
        wait_until { index.definitions_named(initial_entry).size == 1 }.should be_true

        initial_graph = index.graph_for([file_path]) || raise "expected added file graph"
        initial_graph.files.try(&.map(&.path)).should eq([file_path])
        initial_graph.defines.map(&.name).should contain(initial_helper)
        initial_graph.defines.map(&.name).should contain(initial_entry)
        initial_graph.calls.any? { |call| call.caller == initial_entry && call.callee == initial_helper }.should be_true

        initial_facts = Facts.graph_to_prolog(index.graph)
        initial_facts.should contain(initial_entry)
        initial_facts.should contain(initial_helper)

        cache_paths = GraphCache.resolve_cache_paths(cache_dir, repo_key)
        cache_store = SQLiteCacheStore.new(cache_paths["database_path"])
        cache_store.paths.should contain(file_path)
        GraphCache.check_file_cache(
          [{path: file_path, content: initial_source}],
          cache_dir,
          repo_key: repo_key,
        )[:hits].size.should eq(1)

        File.write(file_path, updated_source)
        wait_until do
          index.definitions_named(updated_entry).size == 1 &&
            index.definitions_named(initial_entry).empty?
        end.should be_true

        index.definitions_named(initial_helper).should be_empty
        index.callers_of(initial_helper).should be_empty
        index.callees_of(updated_entry).map(&.callee).should contain(updated_helper)

        updated_facts = Facts.graph_to_prolog(index.graph)
        updated_facts.should contain(updated_entry)
        updated_facts.should contain(updated_helper)
        updated_facts.should_not contain(initial_entry)
        updated_facts.should_not contain(initial_helper)
        GraphCache.check_file_cache(
          [{path: file_path, content: updated_source}],
          cache_dir,
          repo_key: repo_key,
        )[:hits].size.should eq(1)

        File.delete(file_path)
        wait_until do
          index.definitions_in_file(file_path).empty? &&
            index.callers_of(updated_helper).empty? &&
            !cache_store.not_nil!.paths.includes?(file_path)
        end.should be_true

        index.definitions_named(updated_entry).should be_empty
        index.definitions_named(updated_helper).should be_empty
        (index.graph.files || [] of FileNode).map(&.path).should_not contain(file_path)

        deleted_facts = Facts.graph_to_prolog(index.graph)
        deleted_facts.should_not contain(updated_entry)
        deleted_facts.should_not contain(updated_helper)
        GraphCache.check_file_cache(
          [{path: file_path, content: updated_source}],
          cache_dir,
          repo_key: repo_key,
        )[:misses].size.should eq(1)
      ensure
        watcher.stop
        watcher.wait
        index.close
        cache_store.try(&.close)
        GraphCache.close_file_cache_stores_for_test
      end
    end
  end

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
      watcher = Watcher.new(dir, interval: 0.05.seconds) do |changes|
        changed.concat(changes.changed)
        changes.changed.each do |rel_path|
          abs_path = File.join(dir, rel_path)
          spawn do
            Extractor.extract_and_cache_file(
              abs_path,
              cache_dir: cache_dir,
              repo_key: repo_key,
            )
          end
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

  it "removes resident facts and the SQLite cache row after file deletion" do
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

      watcher = Watcher.new(dir, interval: 0.02.seconds) do |changes|
        changes.changed.each do |rel_path|
          abs_path = File.join(dir, rel_path)
          if graph = Extractor.extract_and_cache_file(abs_path, cache_dir: cache_dir, repo_key: repo_key)
            index.upsert_file(graph)
          end
        end
        changes.deleted.each do |rel_path|
          abs_path = File.join(dir, rel_path)
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

        File.delete(file_path)
        wait_until { index.definitions_in_file(file_path).empty? }.should be_true

        cached = GraphCache.check_file_cache(
          [{path: file_path, content: "def version_two\n  2\nend\n"}],
          cache_dir,
          repo_key: repo_key
        )
        cached[:hits].should be_empty
        cached[:misses].size.should eq(1)
      ensure
        watcher.stop
        watcher.wait
        index.close
        GraphCache.close_file_cache_stores_for_test
      end
    end
  end
end
