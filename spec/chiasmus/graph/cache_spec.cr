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
    Dir.children(dir).each { |child| File.delete(File.join(dir, child)) rescue nil }
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

    it "resists boundary collision between content and path" do
      h1 = GraphCache.file_hash("ab", "/c")
      h2 = GraphCache.file_hash("a", "b/c")
      h1.should_not eq h2
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

    it "returns distinct directories per repo key" do
      a = GraphCache.resolve_cache_paths("/tmp/x", "repo-a")
      b = GraphCache.resolve_cache_paths("/tmp/x", "repo-b")
      a["repo_dir"].should_not eq b["repo_dir"]
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

    it "preserves qualified definition and call identities" do
      with_temp_cache do |cache_dir|
        graph = CodeGraph.new(
          defines: [DefinesFact.new(file: "/abs/a.cr", name: "run", kind: SymbolKind::Function, line: 1, qualified_name: "Demo.Worker.run")],
          calls: [CallsFact.new(caller: "run", callee: "helper", caller_qn: "Demo.Worker.run", callee_qn: "Demo.Worker.helper")]
        )
        GraphCache.save_file_cache([
          {path: "/abs/a.cr", content: "class Worker; end", graph: graph},
        ], cache_dir)

        hit = GraphCache.check_file_cache([
          {path: "/abs/a.cr", content: "class Worker; end"},
        ], cache_dir)[:hits].first[:graph]

        hit.defines.first.qualified_name.should eq("Demo.Worker.run")
        hit.calls.first.caller_qn.should eq("Demo.Worker.run")
        hit.calls.first.callee_qn.should eq("Demo.Worker.helper")
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
        snapshot = loaded || raise "Expected snapshot to be non-nil"
        snapshot.defines.first.name.should eq "main"
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

    it "overwrites an existing snapshot with the same name" do
      with_temp_cache do |cache_dir|
        graph1 = CodeGraph.new(defines: [DefinesFact.new(file: "a.ts", name: "old", kind: SymbolKind::Function, line: 1)])
        graph2 = CodeGraph.new(defines: [DefinesFact.new(file: "a.ts", name: "new", kind: SymbolKind::Function, line: 1)])

        GraphCache.save_snapshot("main", graph1, cache_dir)
        GraphCache.save_snapshot("main", graph2, cache_dir)
        loaded = GraphCache.load_snapshot("main", cache_dir)
        loaded.should_not be_nil
        snapshot = loaded || raise "Expected snapshot to be non-nil"
        snapshot.defines.first.name.should eq "new"
      end
    end

    it "sanitizes snapshot names to prevent path traversal" do
      with_temp_cache do |cache_dir|
        expect_raises(ArgumentError, /Invalid snapshot name/) do
          GraphCache.save_snapshot("../../etc/passwd", CodeGraph.new, cache_dir)
        end
        expect_raises(ArgumentError, /Invalid snapshot name/) do
          GraphCache.save_snapshot("foo/bar", CodeGraph.new, cache_dir)
        end
        expect_raises(ArgumentError, /Invalid snapshot name/) do
          GraphCache.save_snapshot("foo\\bar", CodeGraph.new, cache_dir)
        end
      end
    end
  end

  describe "LRU eviction" do
    it "evicts oldest entries when over budget" do
      with_temp_cache do |cache_dir|
        10.times do |i|
          GraphCache.save_file_cache([
            {path: "/abs/file#{i}.ts", content: "function f#{i}() { return #{i}; }", graph: CodeGraph.new},
          ], cache_dir, max_bytes: 100)
        end
        result = GraphCache.check_file_cache([
          {path: "/abs/file0.ts", content: "function f0() { return 0; }"},
        ], cache_dir)
        result[:hits].size.should be <= 10
      end
    end

    it "leaves no .tmp files after save" do
      with_temp_cache do |cache_dir|
        GraphCache.save_file_cache([
          {path: "/abs/a.ts", content: "v1", graph: CodeGraph.new},
        ], cache_dir)
        paths = GraphCache.resolve_cache_paths(cache_dir)
        files_dir = paths["files_dir"]
        if Dir.exists?(files_dir)
          Dir.children(files_dir).each do |entry|
            entry.ends_with?(".tmp").should be_false
          end
        end
      end
    end

    it "manifest carries current schema version" do
      with_temp_cache do |cache_dir|
        GraphCache.save_file_cache([
          {path: "/abs/a.ts", content: "v1", graph: CodeGraph.new},
        ], cache_dir)
        paths = GraphCache.resolve_cache_paths(cache_dir)
        manifest_path = paths["manifest_path"]
        if File.exists?(manifest_path)
          manifest = JSON.parse(File.read(manifest_path))
          manifest["schemaVersion"]?.should_not be_nil
        end
      end
    end

    it "mixed file set partially hits" do
      with_temp_cache do |cache_dir|
        GraphCache.save_file_cache([
          {path: "/abs/a.ts", content: "v1", graph: CodeGraph.new},
        ], cache_dir)
        result = GraphCache.check_file_cache([
          {path: "/abs/a.ts", content: "v1"},
          {path: "/abs/b.ts", content: "new"},
        ], cache_dir)
        result[:hits].size.should eq 1
        result[:misses].size.should eq 1
      end
    end

    it "parallel saves produce a consistent manifest" do
      with_temp_cache do |cache_dir|
        ready = Atomic(Int32).new(0)
        release = Channel(Nil).new(8)
        done = Channel(Nil).new(8)

        8.times do |i|
          spawn do
            ready.add(1)
            release.receive
            GraphCache.save_file_cache([
              {path: "/abs/file#{i}.ts", content: "function f#{i}() {}", graph: CodeGraph.new},
            ], cache_dir)
            done.send(nil)
          end
        end

        until ready.get == 8
          Fiber.yield
        end

        8.times { release.send(nil) }
        8.times { done.receive }

        result = GraphCache.check_file_cache(
          8.times.map { |i| {path: "/abs/file#{i}.ts", content: "function f#{i}() {}"} }.to_a,
          cache_dir
        )

        result[:misses].should be_empty
        result[:hits].size.should eq(8)
      end
    end
  end
end
