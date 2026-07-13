# Ported from vendor/chiasmus/src/graph/cache.ts
#
# SQLite WAL cache for per-file CodeGraph extraction results, plus atomic JSON
# files for named snapshots. SHA-256 content/path identities preserve worktree
# reuse while SQLite transactions replace the former manifest/blob protocol.

require "openssl"
require "./types"
require "./graph_codec"
require "./sqlite_cache_store"
require "tree-sitter-manager"

module Chiasmus
  module Graph
    DEFAULT_MAX_BYTES = 64 * 1024 * 1024 # 64 MB

    module GraphCache
      extend self

      private alias CacheItem = NamedTuple(path: String, content: String, graph: CodeGraph)
      private alias CacheLookupItem = NamedTuple(path: String, content: String)
      private record FileCacheWriteRequest,
        items : Array(CacheItem),
        cache_dir : String,
        repo_key : String? = nil,
        max_bytes : Int32 = DEFAULT_MAX_BYTES

      private record SnapshotWriteRequest,
        name : String,
        graph : CodeGraph,
        cache_dir : String,
        repo_key : String? = nil

      private record FlushRequest,
        ack : Channel(Bool)

      private alias AsyncWriteRequest = FileCacheWriteRequest | SnapshotWriteRequest | FlushRequest
      private record GitRepoContext,
        repo_root : String,
        common_dir : String

      private record CacheIdentity,
        manifest_path : String,
        hash : String,
        origin_path : String

      @@mutex = Mutex.new
      @@writer_mutex = Mutex.new
      @@write_channel : Channel(AsyncWriteRequest)? = nil
      @@before_file_cache_write_hook : Proc(Nil)? = nil
      @@before_snapshot_write_hook : Proc(Nil)? = nil
      @@store_mutex = Mutex.new
      @@stores = Hash(String, SQLiteCacheStore).new

      # SHA-256(content + \0 + path) → hex digest
      def file_hash(content : String, abs_path : String) : String
        OpenSSL::Digest.new("SHA256").update(content).update("\u0000").update(abs_path).final.hexstring
      end

      def default_repo_key(cwd : String = Dir.current) : String
        key_source = git_repo_context_for(cwd).try(&.common_dir) || canonical_path(cwd)
        OpenSSL::Digest.new("SHA256").update(key_source).final.hexstring[0, 16]
      end

      # Resolve repo_key from nil → default_repo_key (SHA-256 of CWD).
      private def self.resolve_repo_key(repo_key : String?) : String
        repo_key || default_repo_key
      end

      def default_cache_dir : String
        ENV["CHIASMUS_CACHE_DIR"]? || TreeSitterManager::XDG.chiasmus_cache_dir
      end

      def default_max_bytes_per_repo : Int32
        if env = ENV["CHIASMUS_CACHE_MAX_PER_REPO"]?
          n = env.to_i32?
          return n if n && n > 0
        end
        DEFAULT_MAX_BYTES
      end

      def resolve_cache_paths(cache_dir : String, repo_key : String? = nil) : Hash(String, String)
        repo_key = resolve_repo_key(repo_key)
        repo_dir = File.join(cache_dir, repo_key)
        {
          "cache_dir"     => cache_dir,
          "repo_dir"      => repo_dir,
          "files_dir"     => File.join(repo_dir, "files"),
          "manifest_path" => File.join(repo_dir, "manifest.json"),
          "database_path" => File.join(repo_dir, "graph-cache.sqlite3"),
        }
      end

      # Check which files are cached. Returns {hits: [...], misses: [...]}.
      # Unlocked reads — safe because manifest writes are atomic (tmp + rename).
      def check_file_cache(
        files : Array(NamedTuple(path: String, content: String)),
        cache_dir : String,
        repo_key : String? = nil,
      ) : NamedTuple(hits: Array(NamedTuple(path: String, graph: CodeGraph)), misses: Array(NamedTuple(path: String, content: String)))
        paths = resolve_cache_paths(cache_dir, repo_key)
        identities = build_cache_identities(files)
        store = sqlite_store(paths["database_path"])

        hits = [] of NamedTuple(path: String, graph: CodeGraph)
        misses = [] of NamedTuple(path: String, content: String)

        files.each_with_index do |file_info, index|
          identity = identities[index]
          if entry = store.fetch(identity.manifest_path, identity.hash)
            begin
              graph = rewrite_cached_graph_paths(
                GraphCodec.decode(entry.payload),
                entry.origin_path,
                file_info[:path]
              )
              hits << {path: file_info[:path], graph: graph}
            rescue
              misses << file_info
            end
          else
            misses << file_info
          end
        end

        {hits: hits, misses: misses}
      end

      # Save extracted graphs to cache. Atomic writes (tmp + rename).
      def save_file_cache(
        items : Array(CacheItem),
        cache_dir : String,
        repo_key : String? = nil,
        max_bytes : Int32 = DEFAULT_MAX_BYTES,
      ) : Nil
        return if items.empty?
        before_file_cache_write_hook.try(&.call)
        paths = resolve_cache_paths(cache_dir, repo_key)
        identities = build_cache_identities(items.map { |item| {path: item[:path], content: item[:content]} })
        now = Time.utc.to_unix_ms
        entries = items.map_with_index do |item, index|
          identity = identities[index]
          payload = GraphCodec.encode(item[:graph])
          SQLiteCacheEntry.new(identity.manifest_path, identity.hash, identity.origin_path, payload, payload.bytesize.to_i64, now)
        end
        store = sqlite_store(paths["database_path"])
        store.apply_batch(entries, [] of String)
        store.evict_over_budget(max_bytes)
      end

      def save_file_cache_async(
        items : Array(CacheItem),
        cache_dir : String,
        repo_key : String? = nil,
        max_bytes : Int32 = DEFAULT_MAX_BYTES,
      ) : Nil
        return if items.empty?
        async_write_channel.send(FileCacheWriteRequest.new(items: items, cache_dir: cache_dir, repo_key: repo_key, max_bytes: max_bytes))
      end

      def evict_lru(cache_dir : String, repo_key : String? = nil, max_bytes : Int32 = DEFAULT_MAX_BYTES) : Nil
        sqlite_store(resolve_cache_paths(cache_dir, repo_key)["database_path"]).evict_over_budget(max_bytes)
      end

      def clear_repo_cache(cache_dir : String, repo_key : String? = nil) : Nil
        paths = resolve_cache_paths(cache_dir, repo_key)
        close_sqlite_store(paths["database_path"])
        FileUtils.rm_rf(paths["repo_dir"]) rescue nil
      end

      # Invalidate cache entries for specific file paths.
      # Removes manifest entries and cached files so the next extraction
      # will regenerate from scratch instead of returning stale data.
      # Lock is held only for the manifest read-modify-write cycle (fast);
      # cache file deletion happens outside the lock.
      def invalidate_file_cache(
        file_paths : Array(String),
        cache_dir : String,
        repo_key : String? = nil,
      ) : Nil
        paths = resolve_cache_paths(cache_dir, repo_key)
        keys = file_paths.map do |abs_path|
          if context = git_repo_context_for(abs_path)
            repo_relative_path(context.repo_root, abs_path) || abs_path
          else
            abs_path
          end
        end
        sqlite_store(paths["database_path"]).apply_batch([] of SQLiteCacheEntry, keys)
      end

      # --- Snapshots ---

      def save_snapshot(name : String, graph : CodeGraph, cache_dir : String, repo_key : String? = nil) : Nil
        validate_snapshot_name(name)

        before_snapshot_write_hook.try(&.call)
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          snap_dir = File.join(paths["repo_dir"], "snapshots")
          Dir.mkdir_p(snap_dir)

          target = File.join(snap_dir, "#{name}.json")
          tmp = unique_tmp_path(target)
          File.write(tmp, GraphCodec.encode(graph))
          File.rename(tmp, target)
        end
      end

      def save_snapshot_async(name : String, graph : CodeGraph, cache_dir : String, repo_key : String? = nil) : Nil
        validate_snapshot_name(name)
        async_write_channel.send(SnapshotWriteRequest.new(name: name, graph: graph, cache_dir: cache_dir, repo_key: repo_key))
      end

      def flush_async_writes : Nil
        ack = Channel(Bool).new(1)
        async_write_channel.send(FlushRequest.new(ack: ack))
        ack.receive?
      end

      def load_snapshot(name : String, cache_dir : String, repo_key : String? = nil) : CodeGraph?
        paths = resolve_cache_paths(cache_dir, repo_key)
        target = File.join(paths["repo_dir"], "snapshots", "#{name}.json")
        return nil unless File.exists?(target)
        GraphCodec.decode(File.read(target))
      rescue
        nil
      end

      def list_snapshots(cache_dir : String, repo_key : String? = nil) : Array(String)
        paths = resolve_cache_paths(cache_dir, repo_key)
        snap_dir = File.join(paths["repo_dir"], "snapshots")
        return [] of String unless Dir.exists?(snap_dir)
        Dir.children(snap_dir)
          .select(&.ends_with?(".json"))
          .map(&.sub(/\.json$/, ""))
      rescue
        [] of String
      end

      def delete_snapshot(name : String, cache_dir : String, repo_key : String? = nil) : Nil
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          target = File.join(paths["repo_dir"], "snapshots", "#{name}.json")
          File.delete(target) if File.exists?(target)
        end
      rescue
      end

      def set_before_file_cache_write_hook_for_test(&block : ->) : Nil
        @@writer_mutex.synchronize { @@before_file_cache_write_hook = block }
      end

      def clear_before_file_cache_write_hook_for_test : Nil
        @@writer_mutex.synchronize { @@before_file_cache_write_hook = nil }
      end

      def set_before_snapshot_write_hook_for_test(&block : ->) : Nil
        @@writer_mutex.synchronize { @@before_snapshot_write_hook = block }
      end

      def clear_before_snapshot_write_hook_for_test : Nil
        @@writer_mutex.synchronize { @@before_snapshot_write_hook = nil }
      end

      def close_file_cache_stores : Nil
        stores = @@store_mutex.synchronize do
          values = @@stores.values
          @@stores.clear
          values
        end
        stores.each(&.close)
      end

      def close_file_cache_stores_for_test : Nil
        close_file_cache_stores
      end

      # --- Private helpers ---

      private def sqlite_store(database_path : String) : SQLiteCacheStore
        @@store_mutex.synchronize do
          @@stores[database_path] ||= SQLiteCacheStore.new(database_path)
        end
      end

      private def close_sqlite_store(database_path : String) : Nil
        store = @@store_mutex.synchronize { @@stores.delete(database_path) }
        store.try(&.close)
      end

      private def async_write_channel : Channel(AsyncWriteRequest)
        @@writer_mutex.synchronize do
          if channel = @@write_channel
            channel
          else
            channel = Channel(AsyncWriteRequest).new(32)
            spawn { process_async_writes(channel) }
            @@write_channel = channel
            channel
          end
        end
      end

      private def process_async_writes(channel : Channel(AsyncWriteRequest)) : Nil
        while request = channel.receive?
          begin
            case request
            when FileCacheWriteRequest
              save_file_cache(request.items, request.cache_dir, repo_key: request.repo_key, max_bytes: request.max_bytes)
            when SnapshotWriteRequest
              save_snapshot(request.name, request.graph, request.cache_dir, repo_key: request.repo_key)
            when FlushRequest
              request.ack.send(true)
            end
          rescue ex
            # A removed repository/cache directory must not kill the singleton
            # writer and strand every later snapshot or flush request.
            STDERR.puts "[Chiasmus] async cache write failed: #{ex.message}"
          end
        end
      end

      private def before_file_cache_write_hook : Proc(Nil)?
        @@writer_mutex.synchronize { @@before_file_cache_write_hook }
      end

      private def before_snapshot_write_hook : Proc(Nil)?
        @@writer_mutex.synchronize { @@before_snapshot_write_hook }
      end

      private def validate_snapshot_name(name : String) : Nil
        raise ArgumentError.new("Snapshot name cannot be empty") if name.empty?
        raise ArgumentError.new("Invalid snapshot name: #{name}") if name.includes?('/') || name.includes?('\\') || name.includes?('\0')
      end

      private def build_cache_identities(files : Array(CacheLookupItem)) : Array(CacheIdentity)
        identities = Array(CacheIdentity?).new(files.size, nil)
        repo_groups = Hash(String, Array(NamedTuple(index: Int32, file: CacheLookupItem, rel_path: String, context: GitRepoContext))).new do |hash, key|
          hash[key] = [] of NamedTuple(index: Int32, file: CacheLookupItem, rel_path: String, context: GitRepoContext)
        end

        files.each_with_index do |file_info, index|
          if context = git_repo_context_for(file_info[:path])
            if rel_path = repo_relative_path(context.repo_root, file_info[:path])
              repo_groups[context.repo_root] << {index: index.to_i32, file: file_info, rel_path: rel_path, context: context}
              next
            end
          end

          identities[index] = CacheIdentity.new(
            manifest_path: file_info[:path],
            hash: file_hash(file_info[:content], file_info[:path]),
            origin_path: file_info[:path]
          )
        end

        repo_groups.each_value do |group|
          context = group.first[:context]
          rel_paths = group.map(&.[:rel_path])
          rel_paths.uniq!
          dirty_paths = git_dirty_paths(context.repo_root, rel_paths)
          clean_paths = rel_paths.reject { |rel_path| dirty_paths.includes?(rel_path) }
          blob_map = git_blob_oids(context.repo_root, clean_paths)

          group.each do |entry|
            logical_path = entry[:rel_path]
            hash = if dirty_paths.includes?(logical_path)
                     file_hash(entry[:file][:content], logical_path)
                   elsif blob_oid = blob_map[logical_path]?
                     git_blob_hash(blob_oid, logical_path)
                   else
                     file_hash(entry[:file][:content], logical_path)
                   end

            identities[entry[:index]] = CacheIdentity.new(
              manifest_path: logical_path,
              hash: hash,
              origin_path: entry[:file][:path]
            )
          end
        end

        identities.map do |identity|
          identity || raise "missing cache identity"
        end
      end

      private def git_blob_hash(blob_oid : String, logical_path : String) : String
        OpenSSL::Digest.new("SHA256").update(blob_oid).update("\u0000").update(logical_path).final.hexstring
      end

      private def rewrite_cached_graph_paths(graph : CodeGraph, from_path : String, to_path : String) : CodeGraph
        return graph if from_path == to_path

        files = graph.files.try &.map do |file_node|
          next file_node unless file_node.path == from_path
          FileNode.new(
            path: to_path,
            language: file_node.language,
            line_count: file_node.line_count,
            token_estimate: file_node.token_estimate,
            file_doc: file_node.file_doc
          )
        end

        type_info = graph.type_info.try &.map do |type_entry|
          next type_entry unless type_entry.file == from_path
          FileTypeInfo.new(
            file: to_path,
            class_fields: type_entry.class_fields,
            class_methods: type_entry.class_methods,
            class_extends: type_entry.class_extends,
            pending_calls: type_entry.pending_calls
          )
        end

        CodeGraph.new(
          defines: graph.defines.map { |defn| defn.file == from_path ? DefinesFact.new(file: to_path, name: defn.name, kind: defn.kind, line: defn.line, end_line: defn.end_line, signature: defn.signature, qualified_name: defn.qualified_name) : defn },
          calls: graph.calls,
          imports: graph.imports.map { |imp| imp.file == from_path ? ImportsFact.new(file: to_path, name: imp.name, source: imp.source) : imp },
          exports: graph.exports.map { |exp| exp.file == from_path ? ExportsFact.new(file: to_path, name: exp.name) : exp },
          contains: graph.contains,
          files: files,
          type_info: type_info
        )
      end

      private def git_repo_context_for(path : String) : GitRepoContext?
        current = canonical_path(Dir.exists?(path) ? path : File.dirname(path))

        loop do
          git_entry = File.join(current, ".git")
          if Dir.exists?(git_entry)
            git_dir = canonical_path(git_entry)
            if File.file?(File.join(git_dir, "HEAD"))
              return GitRepoContext.new(repo_root: current, common_dir: git_common_dir_for(git_dir))
            end
          end

          if File.file?(git_entry)
            if git_dir = parse_git_dir_pointer(git_entry)
              return GitRepoContext.new(repo_root: current, common_dir: git_common_dir_for(git_dir))
            end
          end

          parent = File.dirname(current)
          return nil if parent == current
          current = parent
        end
      rescue
        nil
      end

      private def parse_git_dir_pointer(git_file : String) : String?
        line = File.read_lines(git_file).first?
        return nil unless line
        prefix = "gitdir: "
        return nil unless line.starts_with?(prefix)
        canonical_path(File.expand_path(line[prefix.size..], File.dirname(git_file)))
      rescue
        nil
      end

      private def git_common_dir_for(git_dir : String) : String
        common_dir_file = File.join(git_dir, "commondir")
        return canonical_path(git_dir) unless File.file?(common_dir_file)
        rel_path = File.read(common_dir_file).strip
        return canonical_path(git_dir) if rel_path.empty?
        canonical_path(File.expand_path(rel_path, git_dir))
      rescue
        canonical_path(git_dir)
      end

      private def repo_relative_path(repo_root : String, abs_path : String) : String?
        root = canonical_path(repo_root)
        path = canonical_path(abs_path)
        prefix = "#{root}/"
        return nil unless path.starts_with?(prefix)
        path.byte_slice(prefix.bytesize, path.bytesize - prefix.bytesize)
      end

      private def canonical_path(path : String) : String
        File.realpath(path)
      rescue
        File.expand_path(path)
      end

      private def git_dirty_paths(repo_root : String, rel_paths : Array(String)) : Set(String)
        return Set(String).new if rel_paths.empty?
        output = git_capture(repo_root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + rel_paths)
        return rel_paths.to_set unless output

        dirty = Set(String).new
        entries = output.split('\0')
        index = 0
        while index < entries.size
          entry = entries[index]
          index += 1
          next if entry.empty? || entry.size < 4

          status = entry[0, 2]
          path = entry[3..]
          dirty.add(path) if path

          if status && (status.includes?('R') || status.includes?('C'))
            other = entries[index]?
            dirty.add(other) if other && !other.empty?
            index += 1
          end
        end

        dirty
      end

      private def git_blob_oids(repo_root : String, rel_paths : Array(String)) : Hash(String, String)
        return Hash(String, String).new if rel_paths.empty?
        output = git_capture(repo_root, ["ls-files", "--stage", "-z", "--"] + rel_paths)
        return Hash(String, String).new unless output

        oids = Hash(String, String).new
        output.split('\0').each do |entry|
          next if entry.empty?
          if match = /^(?:\d+)\s+([0-9a-f]+)\s+\d\t(.+)$/.match(entry)
            oids[match[2]] = match[1]
          end
        end
        oids
      end

      private def git_capture(repo_root : String, args : Array(String)) : String?
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("git", ["-C", repo_root] + args, output: output, error: error)
        return nil unless status.success?
        output.to_s
      rescue
        nil
      end

      private def unique_tmp_path(path : String) : String
        "#{path}.tmp.#{Random::Secure.hex(8)}"
      end
    end
  end
end
