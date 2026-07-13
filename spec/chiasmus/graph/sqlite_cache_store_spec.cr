require "../../spec_helper"
require "../../../src/chiasmus/graph/sqlite_cache_store"

include Chiasmus::Graph

describe SQLiteCacheStore do
  it "atomically applies added, modified, and deleted file entries in WAL mode" do
    dir = File.tempname("chiasmus-sqlite-cache")
    Dir.mkdir_p(dir)
    store = SQLiteCacheStore.new(File.join(dir, "graph-cache.sqlite3"))

    begin
      store.journal_mode.downcase.should eq("wal")
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
end
