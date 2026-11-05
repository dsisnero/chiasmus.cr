require "sqlite3"
require "wait_group"

module Chiasmus
  module Graph
    # A store was closed while its caller was waiting to start an operation.
    class CacheClosedError < Exception
    end

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
      FETCH_BATCH_SIZE = 400
      # Bound each write statement group. The read path already chunks at
      # FETCH_BATCH_SIZE; without a matching write bound a single batch (for
      # example hundreds of deleted files) turned into thousands of statements
      # in one transaction while other writers waited.
      WRITE_BATCH_SIZE = 400

      getter path : String
      @db : DB::Database

      def initialize(@path : String)
        @lease_mutex = Mutex.new
        @lease_wg = WaitGroup.new
        @closed = false
        @close_done = Channel(Nil).new(1)
        Dir.mkdir_p(File.dirname(@path))
        @db = DB.open("sqlite3:#{@path}?journal_mode=wal&synchronous=normal&busy_timeout=5000&max_pool_size=4&max_idle_pool_size=4")
        migrate
      end

      def fetch(path : String, content_hash : String) : SQLiteCacheEntry?
        fetch_many([{path: path, content_hash: content_hash}]).first?
      end

      def fetch_many(
        keys : Array(NamedTuple(path: String, content_hash: String)),
      ) : Array(SQLiteCacheEntry?)
        return [] of SQLiteCacheEntry? if keys.empty?

        with_lease do
          paths = keys.map(&.[:path]).uniq!
          matches = {} of Tuple(String, String) => SQLiteCacheEntry

          paths.each_slice(FETCH_BATCH_SIZE) do |batch|
            placeholders = Array(String).new(batch.size, "?").join(',')
            rows = @db.query_all(
              "SELECT path, content_hash, origin_path, payload, size, saved_at_ms FROM cache_entries WHERE path IN (#{placeholders})",
              args: batch,
              as: {String, String, String, String, Int64, Int64},
            )
            rows.each do |row|
              matches[{row[0], row[1]}] = SQLiteCacheEntry.new(row[0], row[1], row[2], row[3], row[4], row[5])
            end
          end

          results = keys.map { |key| matches[{key[:path], key[:content_hash]}]? }
          touch(results.compact_map { |entry| entry.try(&.path) }.uniq!)
          results
        end
      end

      def apply_batch(upserts : Array(SQLiteCacheEntry), deletes : Array(String)) : Nil
        with_lease do
          @db.transaction do |transaction|
            connection = transaction.connection
            deletes.each_slice(WRITE_BATCH_SIZE) do |batch|
              placeholders = Array(String).new(batch.size, "?").join(',')
              connection.exec("DELETE FROM cache_entries WHERE path IN (#{placeholders})", args: batch)
            end

            upserts.each_slice(WRITE_BATCH_SIZE) do |batch|
              batch.each do |entry|
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
        end
      end

      def paths : Array(String)
        with_lease { @db.query_all("SELECT path FROM cache_entries ORDER BY path", as: String) }
      end

      def size : Int64
        with_lease { @db.scalar("SELECT COUNT(*) FROM cache_entries").as(Int64) }
      end

      # Evict least-recently-read entries until the payload byte budget fits.
      # fetch updates saved_at_ms, so it doubles as the LRU access timestamp.
      def evict_over_budget(max_bytes : Int32) : Nil
        with_lease do
          @db.transaction do |transaction|
            connection = transaction.connection
            total = connection.scalar("SELECT COALESCE(SUM(size), 0) FROM cache_entries").as(Int64)
            while total > max_bytes
              oldest = connection.query_one?(
                "SELECT path, size FROM cache_entries ORDER BY saved_at_ms, path LIMIT 1",
                as: {String, Int64},
              )
              break unless oldest
              connection.exec("DELETE FROM cache_entries WHERE path = ?", oldest[0])
              total -= oldest[1]
            end
          end
        end
      end

      def journal_mode : String
        with_lease { @db.scalar("PRAGMA journal_mode").as(String) }
      end

      def schema_version : Int64
        with_lease { @db.scalar("PRAGMA user_version").as(Int64) }
      end

      def close : Nil
        first_close = @lease_mutex.synchronize do
          if @closed
            false
          else
            @closed = true
          end
        end
        unless first_close
          @close_done.receive?
          return
        end

        begin
          @lease_wg.wait
          @db.close
        ensure
          @close_done.close
        end
      end

      # Keep the database open for the duration of an operation. Closing first
      # rejects later callers; closing second waits for existing callers.
      def with_lease(&block : -> T) : T forall T
        @lease_mutex.synchronize do
          raise CacheClosedError.new("graph cache store is closed") if @closed
          @lease_wg.add
        end
        begin
          block.call
        ensure
          @lease_wg.done
        end
      end

      private def touch(paths : Array(String)) : Nil
        return if paths.empty?

        now = Time.utc.to_unix_ms
        @db.transaction do |transaction|
          connection = transaction.connection
          paths.each_slice(FETCH_BATCH_SIZE) do |batch|
            placeholders = Array(String).new(batch.size, "?").join(',')
            args = [] of DB::Any
            args << now
            batch.each { |path| args << path }
            connection.exec(
              "UPDATE cache_entries SET saved_at_ms = ? WHERE path IN (#{placeholders})",
              args: args,
            )
          end
        end
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
        @db.exec("PRAGMA user_version = 1")
      end
    end
  end
end
