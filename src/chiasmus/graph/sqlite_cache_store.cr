require "sqlite3"

module Chiasmus
  module Graph
    record SQLiteCacheEntry,
      path : String,
      content_hash : String,
      origin_path : String,
      payload : String,
      size : Int64,
      saved_at_ms : Int64

    # Transactional per-file graph cache metadata and payload storage.
    # SQLite owns the B-tree/page cache; callers do not mirror the manifest.
    class SQLiteCacheStore
      getter path : String
      @db : DB::Database

      def initialize(@path : String)
        Dir.mkdir_p(File.dirname(@path))
        @db = DB.open("sqlite3:#{@path}?journal_mode=wal&synchronous=normal&busy_timeout=5000")
        migrate
      end

      def fetch(path : String, content_hash : String) : SQLiteCacheEntry?
        @db.query_one?(
          "SELECT path, content_hash, origin_path, payload, size, saved_at_ms FROM cache_entries WHERE path = ? AND content_hash = ?",
          path,
          content_hash,
          as: {String, String, String, String, Int64, Int64},
        ).try do |row|
          SQLiteCacheEntry.new(row[0], row[1], row[2], row[3], row[4], row[5])
        end
      end

      def apply_batch(upserts : Array(SQLiteCacheEntry), deletes : Array(String)) : Nil
        @db.transaction do |transaction|
          connection = transaction.connection
          deletes.each do |path|
            connection.exec("DELETE FROM cache_entries WHERE path = ?", path)
          end
          upserts.each do |entry|
            connection.exec(<<-SQL, entry.path, entry.content_hash, entry.origin_path, entry.payload, entry.size, entry.saved_at_ms)
              INSERT INTO cache_entries(path, content_hash, origin_path, payload, size, saved_at_ms)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(path) DO UPDATE SET
                content_hash = excluded.content_hash,
                origin_path = excluded.origin_path,
                payload = excluded.payload,
                size = excluded.size,
                saved_at_ms = excluded.saved_at_ms
              SQL
          end
        end
      end

      def paths : Array(String)
        @db.query_all("SELECT path FROM cache_entries ORDER BY path", as: String)
      end

      def size : Int64
        @db.scalar("SELECT COUNT(*) FROM cache_entries").as(Int64)
      end

      def journal_mode : String
        @db.scalar("PRAGMA journal_mode").as(String)
      end

      def close : Nil
        @db.close
      end

      private def migrate : Nil
        @db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS cache_entries (
            path TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            origin_path TEXT NOT NULL,
            payload BLOB NOT NULL,
            size INTEGER NOT NULL,
            saved_at_ms INTEGER NOT NULL
          )
          SQL
      end
    end
  end
end
