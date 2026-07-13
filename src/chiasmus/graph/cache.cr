# Ported from vendor/chiasmus/src/graph/cache.ts
#
# On-disk cache for per-file CodeGraph extraction results.
# SHA-256 content+path keying, atomic writes, LRU eviction by mtime.
# Single-process (no file locking).

require "openssl"
require "json"
require "./types"
require "tree-sitter-manager"

module Chiasmus
  module Graph
    CACHE_SCHEMA_VERSION = "5"

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
        manifest = load_manifest(paths)
        identities = build_cache_identities(files)

        hits = [] of NamedTuple(path: String, graph: CodeGraph)
        misses = [] of NamedTuple(path: String, content: String)

        files.each_with_index do |file_info, index|
          identity = identities[index]
          entry = manifest["entries"].as_h[identity.manifest_path]?
          entry_hash = entry.try(&.["hash"].as_s)
          if entry_hash && entry_hash == identity.hash
            cache_path = File.join(paths["files_dir"], "#{identity.hash}.json")
            begin
              raw = File.read(cache_path)
              graph = rewrite_cached_graph_paths(
                code_graph_from_json(raw),
                entry_origin_path(entry) || identity.origin_path,
                file_info[:path]
              )
              # Best-effort mtime bump for LRU
              File.utime(Time.utc, Time.utc, cache_path) rescue nil
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
        superseded_hashes = [] of String
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          Dir.mkdir_p(paths["files_dir"])

          manifest = load_manifest(paths)
          identities = build_cache_identities(items.map { |item| {path: item[:path], content: item[:content]} })

          items.each_with_index do |item, index|
            identity = identities[index]
            entry = manifest["entries"].as_h
            if previous = entry[identity.manifest_path]?
              previous_hash = previous["hash"]?.try(&.as_s?)
              superseded_hashes << previous_hash if previous_hash && previous_hash != identity.hash
            end

            serialized = code_graph_to_json(item[:graph])
            cache_path = File.join(paths["files_dir"], "#{identity.hash}.json")
            tmp = unique_tmp_path(cache_path)
            File.write(tmp, serialized)
            File.rename(tmp, cache_path)

            entry[identity.manifest_path] = JSON.parse({
              "hash"       => identity.hash,
              "size"       => serialized.bytesize.to_s,
              "savedAt"    => Time.utc.to_unix_ms.to_s,
              "originPath" => identity.origin_path,
            }.to_json)
          end

          write_manifest(paths, manifest)
          evict_if_over_budget(paths, manifest, max_bytes)
        end

        files_dir = resolve_cache_paths(cache_dir, repo_key)["files_dir"]
        superseded_hashes.uniq!.each do |hash|
          File.delete(File.join(files_dir, "#{hash}.json")) rescue nil
        end
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
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          manifest = load_manifest(paths)
          evict_if_over_budget(paths, manifest, max_bytes)
        end
      end

      def clear_repo_cache(cache_dir : String, repo_key : String? = nil) : Nil
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          FileUtils.rm_rf(paths["repo_dir"]) rescue nil
        end
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
        stale_hashes = [] of String

        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          manifest = load_manifest(paths)
          entries = manifest["entries"].as_h
          modified = false

          file_paths.each do |abs_path|
            manifest_key = if ctx = git_repo_context_for(abs_path)
                             repo_relative_path(ctx.repo_root, abs_path) || abs_path
                           else
                             abs_path
                           end

            if entry = entries.delete(manifest_key)
              modified = true
              if hash_val = entry["hash"]?.try(&.as_s?)
                stale_hashes << hash_val
              end
            end
          end

          if modified
            write_manifest(paths, manifest)
          end
          prune_orphaned_file_cache(paths, entries)
        end

        # Delete stale cache files outside the lock.
        files_dir = resolve_cache_paths(cache_dir, repo_key)["files_dir"]
        stale_hashes.each do |hash|
          File.delete(File.join(files_dir, "#{hash}.json")) rescue nil
        end
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
          File.write(tmp, code_graph_to_json(graph))
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
        code_graph_from_json(File.read(target))
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

      # --- Private helpers ---

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

      private def entry_origin_path(entry : JSON::Any?) : String?
        entry.try(&.as_h["originPath"]?).try(&.as_s?)
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

      private def load_manifest(paths : Hash(String, String)) : Hash(String, JSON::Any)
        unless File.exists?(paths["manifest_path"])
          return Hash(String, JSON::Any).new.tap { |hash|
            hash["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION)
            hash["entries"] = JSON.parse(%({}))
          }
        end
        raw = File.read(paths["manifest_path"]) rescue return Hash(String, JSON::Any).new.tap { |hash| hash["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION); hash["entries"] = JSON.parse(%({})) }
        parsed = JSON.parse(raw).as_h
        schema = parsed["schemaVersion"]?
        unless schema && schema.raw.is_a?(String) && schema.raw.as(String) == CACHE_SCHEMA_VERSION
          return Hash(String, JSON::Any).new.tap { |hash|
            hash["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION)
            hash["entries"] = JSON.parse(%({}))
          }
        end
        parsed
      end

      private def write_manifest(paths : Hash(String, String), manifest : Hash(String, JSON::Any)) : Nil
        tmp = unique_tmp_path(paths["manifest_path"])
        File.write(tmp, manifest.to_json)
        File.rename(tmp, paths["manifest_path"])
      end

      private def fresh_manifest : JSON::Any
        JSON.parse({
          "schemaVersion" => CACHE_SCHEMA_VERSION,
          "entries"       => {} of String => Hash(String, JSON::Any),
        }.to_json)
      end

      private def code_graph_to_json(graph : CodeGraph) : String
        json = {
          "defines" => graph.defines.map { |defn|
            h = {"file" => defn.file, "name" => defn.name, "kind" => defn.kind.to_s, "line" => defn.line}
            h = h.merge({"end_line" => defn.end_line}) if defn.end_line > 0
            h = h.merge({"qualified_name" => defn.qualified_name}) if defn.qualified_name
            h
          },
          "calls" => graph.calls.map { |call_fact|
            h = {"caller" => call_fact.caller, "callee" => call_fact.callee}
            callee_qn = call_fact.callee_qn
            h = h.merge({"callee_qn" => callee_qn}) if callee_qn
            caller_qn = call_fact.caller_qn
            h = h.merge({"caller_qn" => caller_qn}) if caller_qn
            h
          },
          "imports"  => graph.imports.map { |i| {"file" => i.file, "name" => i.name, "source" => i.source} },
          "exports"  => graph.exports.map { |e| {"file" => e.file, "name" => e.name} },
          "contains" => graph.contains.map { |cont| {"parent" => cont.parent, "child" => cont.child} },
        }
        graph.files.try do |fns|
          json = json.merge({
            "files" => fns.map { |file_node|
              h = {"path" => file_node.path, "language" => file_node.language}
              h = h.merge({"line_count" => file_node.line_count}) if file_node.line_count
              h = h.merge({"token_estimate" => file_node.token_estimate}) if file_node.token_estimate
              h = h.merge({"file_doc" => file_node.file_doc}) if file_node.file_doc
              h
            },
          })
        end
        graph.type_info.try do |type_inf|
          json = json.merge({
            "_typeInfo" => type_inf.map { |type_entry|
              h = {"file" => type_entry.file}
              h = h.merge({"class_fields" => type_entry.class_fields.map { |class_field|
                {"class_name" => class_field.class_name, "fields" => class_field.fields}
              }})
              h = h.merge({"class_methods" => type_entry.class_methods.try(&.map { |class_meth|
                {"class_name" => class_meth.class_name, "methods" => class_meth.methods}
              })}) if type_entry.class_methods
              h = h.merge({"class_extends" => type_entry.class_extends.try(&.map { |class_ext|
                {"class_name" => class_ext.class_name, "parent" => class_ext.parent}
              })}) if type_entry.class_extends
              h = h.merge({"pending_calls" => type_entry.pending_calls.map { |pending|
                {
                  "caller"          => pending.caller,
                  "callee"          => pending.callee,
                  "receiver_chain"  => pending.receiver_chain,
                  "enclosing_class" => pending.enclosing_class,
                  "var_types"       => pending.var_types,
                }
              }})
              h
            },
          })
        end
        json.to_json
      end

      private def code_graph_from_json(raw : String) : CodeGraph
        parsed = JSON.parse(raw)
        files = parsed["files"]?.try do |fns|
          fns.as_a.map { |file_node|
            h = file_node.as_h
            FileNode.new(
              path: h["path"].as_s,
              language: h["language"].as_s,
              line_count: h["line_count"]?.try(&.as_i?),
              token_estimate: h["token_estimate"]?.try(&.as_i?),
              file_doc: h["file_doc"]?.try(&.as_s?),
            )
          }
        end
        type_info = parsed["_typeInfo"]?.try do |entries|
          entries.as_a.map do |type_entry|
            h = type_entry.as_h
            FileTypeInfo.new(
              file: h["file"].as_s,
              class_fields: h["class_fields"]?.try(&.as_a.map { |class_field|
                field_hash = class_field.as_h
                ClassFieldEntry.new(
                  class_name: field_hash["class_name"].as_s,
                  fields: field_hash["fields"].as_h.transform_values(&.as_s)
                )
              }) || [] of ClassFieldEntry,
              class_methods: h["class_methods"]?.try(&.as_a.map { |class_method|
                method_hash = class_method.as_h
                ClassMethodEntry.new(
                  class_name: method_hash["class_name"].as_s,
                  methods: method_hash["methods"].as_a.map(&.as_s)
                )
              }),
              class_extends: h["class_extends"]?.try(&.as_a.map { |class_extend|
                extend_hash = class_extend.as_h
                ClassExtendsEntry.new(
                  class_name: extend_hash["class_name"].as_s,
                  parent: extend_hash["parent"].as_s
                )
              }),
              pending_calls: h["pending_calls"]?.try(&.as_a.map { |pending_call|
                pending_hash = pending_call.as_h
                PendingCall.new(
                  caller: pending_hash["caller"].as_s,
                  callee: pending_hash["callee"].as_s,
                  receiver_chain: pending_hash["receiver_chain"]?.try(&.as_a.map(&.as_s)) || [] of String,
                  enclosing_class: pending_hash["enclosing_class"]?.try(&.as_s?),
                  var_types: pending_hash["var_types"]?.try(&.as_h.transform_values(&.as_s)) || Hash(String, String).new
                )
              }) || [] of PendingCall
            )
          end
        end
        CodeGraph.new(
          defines: parsed["defines"].as_a.map { |defn|
            DefinesFact.new(file: defn["file"].as_s, name: defn["name"].as_s, kind: SymbolKind.parse(defn["kind"].as_s), line: defn["line"].as_i, end_line: defn["end_line"]?.try(&.as_i?) || 0, qualified_name: defn["qualified_name"]?.try(&.as_s?))
          },
          calls: parsed["calls"].as_a.map { |call_fact|
            CallsFact.new(caller: call_fact["caller"].as_s, callee: call_fact["callee"].as_s, callee_qn: call_fact["callee_qn"]?.try(&.as_s?), caller_qn: call_fact["caller_qn"]?.try(&.as_s?))
          },
          imports: parsed["imports"].as_a.map { |i|
            ImportsFact.new(file: i["file"].as_s, name: i["name"].as_s, source: i["source"].as_s)
          },
          exports: parsed["exports"].as_a.map { |e|
            ExportsFact.new(file: e["file"].as_s, name: e["name"].as_s)
          },
          contains: parsed["contains"].as_a.map { |cont|
            ContainsFact.new(parent: cont["parent"].as_s, child: cont["child"].as_s)
          },
          files: files,
          type_info: type_info,
        )
      end

      private def write_manifest(paths : Hash(String, String), manifest : JSON::Any) : Nil
        tmp = unique_tmp_path(paths["manifest_path"])
        File.write(tmp, manifest.to_json)
        File.rename(tmp, paths["manifest_path"])
      end

      # Remove content-addressed graph blobs no longer reachable from the
      # manifest. Deletion invalidation calls this while holding @@mutex, so an
      # async writer cannot publish a new blob between the reference snapshot
      # and the sweep.
      private def prune_orphaned_file_cache(paths : Hash(String, String), entries : Hash(String, JSON::Any)) : Nil
        files_dir = paths["files_dir"]
        return unless Dir.exists?(files_dir)

        referenced = entries.values.compact_map { |entry| entry["hash"]?.try(&.as_s?) }.to_set
        Dir.children(files_dir).each do |name|
          next unless name.ends_with?(".json")
          next if referenced.includes?(name.rchop(".json"))

          File.delete(File.join(files_dir, name)) rescue nil
        end
      end

      private def unique_tmp_path(path : String) : String
        "#{path}.tmp.#{Random::Secure.hex(8)}"
      end

      private def evict_if_over_budget(paths : Hash(String, String), manifest : Hash(String, JSON::Any), budget : Int32) : Nil
        entries = manifest["entries"].as_h
        manifest_total = entries.values.sum(&.["size"].as_s.to_i)
        return if manifest_total <= budget

        files_dir = paths["files_dir"]
        return unless Dir.exists?(files_dir)

        disk_entries = [] of NamedTuple(name: String, size: Int64, mtime: Time, path: String)
        Dir.children(files_dir).each do |name|
          next unless name.ends_with?(".json")
          p = File.join(files_dir, name)
          begin
            st = File.info(p)
            disk_entries << {name: name, size: st.size, mtime: st.modification_time, path: p}
          rescue
          end
        end

        total = disk_entries.sum(&.[:size]).to_i
        return if total <= budget

        disk_entries.sort_by!(&.[:mtime])

        # Build hash→filePath index
        hash_to_path = Hash(String, String).new
        entries.each { |file_path, entry| hash_to_path[entry["hash"].as_s] = file_path }

        changed = false
        disk_entries.each do |e|
          break if total <= budget
          begin
            File.delete(e[:path])
            total -= e[:size].to_i.to_i32
            h = e[:name].sub(/\.json$/, "")
            fp = hash_to_path[h]?
            entries.delete(fp) if fp
            changed = true
          rescue
          end
        end

        write_manifest(paths, manifest) if changed
      end
    end
  end
end
