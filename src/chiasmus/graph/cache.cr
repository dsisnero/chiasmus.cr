# Ported from vendor/chiasmus/src/graph/cache.ts
#
# On-disk cache for per-file CodeGraph extraction results.
# SHA-256 content+path keying, atomic writes, LRU eviction by mtime.
# Single-process (no file locking).

require "openssl"
require "json"
require "./types"
require "../utils/xdg"

module Chiasmus
  module Graph
    CACHE_SCHEMA_VERSION = "3"

    DEFAULT_MAX_BYTES = 64 * 1024 * 1024 # 64 MB

    module GraphCache
      extend self

      @@mutex = Mutex.new

      # SHA-256(content + \0 + path) → hex digest
      def file_hash(content : String, abs_path : String) : String
        OpenSSL::Digest.new("SHA256").update(content).update("\u0000").update(abs_path).final.hexstring
      end

      def default_repo_key(cwd : String = Dir.current) : String
        OpenSSL::Digest.new("SHA256").update(cwd).final.hexstring[0, 16]
      end

      # Resolve repo_key from nil → default_repo_key (SHA-256 of CWD).
      private def self.resolve_repo_key(repo_key : String?) : String
        repo_key || default_repo_key
      end

      def default_cache_dir : String
        ENV["CHIASMUS_CACHE_DIR"]? || Utils::XDG.chiasmus_cache_dir
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

        hits = [] of NamedTuple(path: String, graph: CodeGraph)
        misses = [] of NamedTuple(path: String, content: String)

        files.each do |file_info|
          h = file_hash(file_info[:content], file_info[:path])
          entry = manifest["entries"].as_h[file_info[:path]]?
          entry_hash = entry.try(&.["hash"].as_s)
          if entry_hash && entry_hash == h
            cache_path = File.join(paths["files_dir"], "#{h}.json")
            begin
              raw = File.read(cache_path)
              graph = code_graph_from_json(raw)
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
        items : Array(NamedTuple(path: String, content: String, graph: CodeGraph)),
        cache_dir : String,
        repo_key : String? = nil,
        max_bytes : Int32 = DEFAULT_MAX_BYTES,
      ) : Nil
        return if items.empty?
        @@mutex.synchronize do
          paths = resolve_cache_paths(cache_dir, repo_key)
          Dir.mkdir_p(paths["files_dir"])

          manifest = load_manifest(paths)

          items.each do |item|
            h = file_hash(item[:content], item[:path])
            serialized = code_graph_to_json(item[:graph])
            cache_path = File.join(paths["files_dir"], "#{h}.json")
            tmp = unique_tmp_path(cache_path)
            File.write(tmp, serialized)
            File.rename(tmp, cache_path)

            entry = manifest["entries"].as_h
            entry[item[:path]] = JSON.parse({
              "hash"    => h,
              "size"    => serialized.bytesize.to_s,
              "savedAt" => Time.utc.to_unix_ms.to_s,
            }.to_json)
          end

          write_manifest(paths, manifest)
          evict_if_over_budget(paths, manifest, max_bytes)
        end
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

      # --- Snapshots ---

      def save_snapshot(name : String, graph : CodeGraph, cache_dir : String, repo_key : String? = nil) : Nil
        raise ArgumentError.new("Snapshot name cannot be empty") if name.empty?
        raise ArgumentError.new("Invalid snapshot name: #{name}") if name.includes?('/') || name.includes?('\\') || name.includes?('\0')

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

      # --- Private helpers ---

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
          "defines" => graph.defines.map { |defn| h = {"file" => defn.file, "name" => defn.name, "kind" => defn.kind.to_s, "line" => defn.line}; h = h.merge({"end_line" => defn.end_line}) if defn.end_line > 0; h },
          "calls"   => graph.calls.map { |call_fact|
            h = {"caller" => call_fact.caller, "callee" => call_fact.callee}
            callee_qn = call_fact.callee_qn
            h = h.merge({"callee_qn" => callee_qn}) if callee_qn
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
        CodeGraph.new(
          defines: parsed["defines"].as_a.map { |defn|
            DefinesFact.new(file: defn["file"].as_s, name: defn["name"].as_s, kind: SymbolKind.parse(defn["kind"].as_s), line: defn["line"].as_i, end_line: defn["end_line"]?.try(&.as_i?) || 0)
          },
          calls: parsed["calls"].as_a.map { |call_fact|
            CallsFact.new(caller: call_fact["caller"].as_s, callee: call_fact["callee"].as_s, callee_qn: call_fact["callee_qn"]?.try(&.as_s?))
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
        )
      end

      private def write_manifest(paths : Hash(String, String), manifest : JSON::Any) : Nil
        tmp = unique_tmp_path(paths["manifest_path"])
        File.write(tmp, manifest.to_json)
        File.rename(tmp, paths["manifest_path"])
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
