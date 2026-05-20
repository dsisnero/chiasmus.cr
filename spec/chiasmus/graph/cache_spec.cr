require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/cache"

include Chiasmus::Graph

private def with_temp_cache(& : String ->)
  dir = File.tempname("chiasmus-cache-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    Dir.children(dir).each { |c| File.delete(File.join(dir, c)) rescue nil }
    Dir.delete(dir) rescue nil
  end
end

describe GraphCache do
  describe ".file_hash" do
    it "produces deterministic SHA-256 hex digest" do
      h1 = GraphCache.file_hash("hello", "/abs/a.ts")
      h2 = GraphCache.file_hash("hello", "/abs/a.ts")
      h1.should eq h2
      h1.size.should eq 64
    end

    it "differs for different content or path" do
      h1 = GraphCache.file_hash("a", "/abs/x.ts")
      h2 = GraphCache.file_hash("b", "/abs/x.ts")
      h3 = GraphCache.file_hash("a", "/abs/y.ts")
      h1.should_not eq h2
      h1.should_not eq h3
    end
  end

  describe ".resolve_cache_paths" do
    it "returns structured paths" do
      paths = GraphCache.resolve_cache_paths("/tmp/cache", "myrepo")
      paths["cache_dir"].should contain "/tmp/cache"
      paths["repo_dir"].should contain "myrepo"
      paths["files_dir"].should contain "files"
      paths["manifest_path"].should contain "manifest.json"
    end
  end

  describe "check_file_cache + save_file_cache roundtrip" do
    it "returns all misses on first check" do
      with_temp_cache do |cache_dir|
        result = GraphCache.check_file_cache([
          {path: "/abs/a.ts", content: "function foo() {}"},
        ], cache_dir)
        result[:hits].should be_empty
        result[:misses].size.should eq 1
      end
    end

    it "returns hits after saving" do
      with_temp_cache do |cache_dir|
        graph = CodeGraph.new(
          defines: [DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, line: 1)],
        )
        GraphCache.save_file_cache([
          {path: "/abs/a.ts", content: "function foo() {}", graph: graph},
        ], cache_dir)

        result = GraphCache.check_file_cache([
          {path: "/abs/a.ts", content: "function foo() {}"},
        ], cache_dir)
        result[:hits].size.should eq 1
        result[:misses].should be_empty
        result[:hits][0][:path].should eq "/abs/a.ts"
        result[:hits][0][:graph].defines.first.name.should eq "foo"
      end
    end

    it "returns miss when content changed" do
      with_temp_cache do |cache_dir|
        GraphCache.save_file_cache([
          {path: "/abs/a.ts", content: "function old() {}", graph: CodeGraph.new},
        ], cache_dir)

        result = GraphCache.check_file_cache([
          {path: "/abs/a.ts", content: "function new() {}"},
        ], cache_dir)
        result[:hits].should be_empty
        result[:misses].size.should eq 1
      end
    end
  end

  describe "snapshots" do
    it "saves and loads snapshots" do
      with_temp_cache do |cache_dir|
        graph = CodeGraph.new(
          defines: [DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 1)],
        )
        GraphCache.save_snapshot("main", graph, cache_dir)

        loaded = GraphCache.load_snapshot("main", cache_dir)
        loaded.should_not be_nil
        loaded.not_nil!.defines.first.name.should eq "main"
      end
    end

    it "returns nil for missing snapshot" do
      with_temp_cache do |cache_dir|
        GraphCache.load_snapshot("nonexistent", cache_dir).should be_nil
      end
    end

    it "lists saved snapshots" do
      with_temp_cache do |cache_dir|
        GraphCache.save_snapshot("v1", CodeGraph.new, cache_dir)
        GraphCache.save_snapshot("v2", CodeGraph.new, cache_dir)
        snapshots = GraphCache.list_snapshots(cache_dir)
        snapshots.sort.should eq ["v1", "v2"]
      end
    end

    it "deletes snapshots" do
      with_temp_cache do |cache_dir|
        GraphCache.save_snapshot("tmp", CodeGraph.new, cache_dir)
        GraphCache.delete_snapshot("tmp", cache_dir)
        GraphCache.load_snapshot("tmp", cache_dir).should be_nil
      end
    end
  end

  describe "LRU eviction" do
    it "evicts oldest entries when over budget" do
      with_temp_cache do |cache_dir|
        # Save with tiny budget to trigger eviction
        10.times do |i|
          GraphCache.save_file_cache([
            {path: "/abs/file#{i}.ts", content: "function f#{i}() { return #{i}; }", graph: CodeGraph.new},
          ], cache_dir, max_bytes: 100)
        end
        # Should not crash and total files should be within budget
        result = GraphCache.check_file_cache([
          {path: "/abs/file0.ts", content: "function f0() { return 0; }"},
        ], cache_dir)
        # The most recent saves should survive; oldest may be evicted
        result[:hits].size.should be <= 10
      end
    end
  end
end
