require "../../spec_helper"
require "../../../src/chiasmus/graph/sqlite_cache_store"
require "../../../src/chiasmus/graph/cache"

include Chiasmus::Graph

describe SQLiteCacheStore do
  it "atomically applies added, modified, and deleted file entries in WAL mode" do
    dir = File.tempname("chiasmus-sqlite-cache")
    Dir.mkdir_p(dir)
    store = SQLiteCacheStore.new(File.join(dir, "graph-cache.sqlite3"))

    begin
      store.journal_mode.downcase.should eq("wal")
      store.schema_version.should eq(1)
      first = SQLiteCacheEntry.new("src/a.cr", "hash-a1", "/repo/src/a.cr", %({"defines":["old"]}), 19_i64, 1_i64)
      deleted = SQLiteCacheEntry.new("src/deleted.cr", "hash-d", "/repo/src/deleted.cr", %({"defines":["gone"]}), 20_i64, 1_i64)
      store.apply_batch([first, deleted], [] of String)

      replacement = SQLiteCacheEntry.new("src/a.cr", "hash-a2", "/repo/src/a.cr", %({"defines":["new"]}), 19_i64, 2_i64)
      added = SQLiteCacheEntry.new("src/b.cr", "hash-b", "/repo/src/b.cr", %({"defines":["added"]}), 21_i64, 2_i64)
      store.apply_batch([replacement, added], ["src/deleted.cr"])

      store.paths.should eq(["src/a.cr", "src/b.cr"])
      store.size.should eq(2)
      store.fetch("src/a.cr", "hash-a1").should be_nil
      (store.fetch("src/a.cr", "hash-a2") || raise "expected replacement entry").payload.should contain("new")
      store.fetch("src/deleted.cr", "hash-d").should be_nil
    ensure
      store.close
      FileUtils.rm_rf(dir)
    end
  end

  it "reopens a fresh cache without an in-memory manifest" do
    dir = File.tempname("chiasmus-sqlite-cache-reopen")
    Dir.mkdir_p(dir)
    path = File.join(dir, "graph-cache.sqlite3")

    begin
      first = SQLiteCacheStore.new(path)
      first.apply_batch([
        SQLiteCacheEntry.new("src/a.cr", "hash", "/repo/src/a.cr", "graph", 5_i64, 1_i64),
      ], [] of String)
      first.close

      reopened = SQLiteCacheStore.new(path)
      begin
        reopened.fetch("src/a.cr", "hash").try(&.payload).should eq("graph")
      ensure
        reopened.close
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "fetches matching entries in one batch and refreshes their LRU timestamps" do
    dir = File.tempname("chiasmus-sqlite-cache-fetch-many")
    Dir.mkdir_p(dir)
    store = SQLiteCacheStore.new(File.join(dir, "graph-cache.sqlite3"))

    begin
      store.apply_batch([
        SQLiteCacheEntry.new("src/a.cr", "hash-a", "/repo/src/a.cr", "graph-a", 7_i64, 1_i64),
        SQLiteCacheEntry.new("src/b.cr", "hash-b", "/repo/src/b.cr", "graph-b", 7_i64, 1_i64),
      ], [] of String)

      matches = store.fetch_many([
        {path: "src/a.cr", content_hash: "hash-a"},
        {path: "src/a.cr", content_hash: "stale-a-hash"},
        {path: "src/b.cr", content_hash: "stale-hash"},
        {path: "src/missing.cr", content_hash: "hash-missing"},
      ])

      matched = matches[0] || raise "expected matching batch entry"
      matched.payload.should eq("graph-a")
      matches[1].should be_nil
      matches[2].should be_nil
      matches[3].should be_nil
      refreshed = store.fetch("src/a.cr", "hash-a") || raise "expected refreshed entry"
      untouched = store.fetch("src/b.cr", "hash-b") || raise "expected untouched entry"
      refreshed.saved_at_ms.should be > 1_i64
      untouched.saved_at_ms.should eq(1_i64)
    ensure
      store.close
      FileUtils.rm_rf(dir)
    end
  end
end

describe GraphCache do
  it "persists, replaces, and invalidates file graphs through SQLite" do
    dir = File.tempname("chiasmus-graph-cache-sqlite")
    Dir.mkdir_p(dir)
    path = "/abs/demo.cr"

    begin
      original = CodeGraph.new(defines: [DefinesFact.new(file: path, name: "old", kind: SymbolKind::Method, line: 1)])
      replacement = CodeGraph.new(defines: [DefinesFact.new(file: path, name: "new", kind: SymbolKind::Method, line: 1)])

      GraphCache.save_file_cache([{path: path, content: "old", graph: original}], dir, repo_key: "repo")
      GraphCache.check_file_cache([{path: path, content: "old"}], dir, repo_key: "repo")[:hits].first[:graph].should eq(original)

      GraphCache.save_file_cache([{path: path, content: "new", graph: replacement}], dir, repo_key: "repo")
      GraphCache.check_file_cache([{path: path, content: "old"}], dir, repo_key: "repo")[:misses].size.should eq(1)
      GraphCache.check_file_cache([{path: path, content: "new"}], dir, repo_key: "repo")[:hits].first[:graph].should eq(replacement)

      paths = GraphCache.resolve_cache_paths(dir, "repo")
      File.exists?(paths["database_path"]).should be_true
      File.exists?(paths["manifest_path"]).should be_false
      Dir.exists?(paths["files_dir"]).should be_false

      GraphCache.invalidate_file_cache([path], dir, repo_key: "repo")
      GraphCache.check_file_cache([{path: path, content: "new"}], dir, repo_key: "repo")[:misses].size.should eq(1)
    ensure
      GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
