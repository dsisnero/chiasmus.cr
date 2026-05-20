# Ported from vendor/chiasmus/src/graph/cache.ts
#
# On-disk cache for per-file CodeGraph extraction results.
# SHA-256 content+path keying, atomic writes, LRU eviction by mtime.
# Single-process (no file locking).

require "openssl"
require "json"
require "./types"

module Chiasmus
  module Graph
    CACHE_SCHEMA_VERSION = "3"

    DEFAULT_MAX_BYTES = 64 * 1024 * 1024 # 64 MB

    module GraphCache
      extend self

      # SHA-256(content + \0 + path) → hex digest
      def file_hash(content : String, abs_path : String) : String
        OpenSSL::Digest.new("SHA256").update(content).update("\u0000").update(abs_path).final.hexstring
      end

      def default_repo_key(cwd : String = Dir.current) : String
        OpenSSL::Digest.new("SHA256").update(cwd).final.hexstring[0, 16]
      end

      def resolve_cache_paths(cache_dir : String, repo_key : String = "default") : Hash(String, String)
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
        repo_key : String = "default",
      ) : NamedTuple(hits: Array(NamedTuple(path: String, graph: CodeGraph)), misses: Array(NamedTuple(path: String, content: String)))
        paths = resolve_cache_paths(cache_dir, repo_key)
        manifest = load_manifest(paths)

        hits = [] of NamedTuple(path: String, graph: CodeGraph)
        misses = [] of NamedTuple(path: String, content: String)

        files.each do |f|
          h = file_hash(f[:content], f[:path])
          entry = manifest["entries"].as_h[f[:path]]?
          entry_hash = entry.try { |e| e["hash"].as_s }
          if entry_hash && entry_hash == h
            cache_path = File.join(paths["files_dir"], "#{h}.json")
            begin
              raw = File.read(cache_path)
              graph = code_graph_from_json(raw)
              # Best-effort mtime bump for LRU
              File.utime(Time.utc, Time.utc, cache_path) rescue nil
              hits << {path: f[:path], graph: graph}
            rescue
              misses << f
            end
          else
            misses << f
          end
        end

        {hits: hits, misses: misses}
      end

      # Save extracted graphs to cache. Atomic writes (tmp + rename).
      def save_file_cache(
        items : Array(NamedTuple(path: String, content: String, graph: CodeGraph)),
        cache_dir : String,
        repo_key : String = "default",
        max_bytes : Int32 = DEFAULT_MAX_BYTES,
      ) : Nil
        return if items.empty?
        paths = resolve_cache_paths(cache_dir, repo_key)
        Dir.mkdir_p(paths["files_dir"])

        manifest = load_manifest(paths)

        items.each do |item|
          h = file_hash(item[:content], item[:path])
          serialized = code_graph_to_json(item[:graph])
          cache_path = File.join(paths["files_dir"], "#{h}.json")
          tmp = cache_path + ".tmp"
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

      def evict_lru(cache_dir : String, repo_key : String = "default", max_bytes : Int32 = DEFAULT_MAX_BYTES) : Nil
        paths = resolve_cache_paths(cache_dir, repo_key)
        manifest = load_manifest(paths)
        evict_if_over_budget(paths, manifest, max_bytes)
      end

      def clear_repo_cache(cache_dir : String, repo_key : String = "default") : Nil
        paths = resolve_cache_paths(cache_dir, repo_key)
        FileUtils.rm_rf(paths["repo_dir"]) rescue nil
      end

      # --- Snapshots ---

      def save_snapshot(name : String, graph : CodeGraph, cache_dir : String, repo_key : String = "default") : Nil
        raise ArgumentError.new("Snapshot name cannot be empty") if name.empty?
        raise ArgumentError.new("Invalid snapshot name: #{name}") if name.includes?('/') || name.includes?('\\') || name.includes?('\0')

        paths = resolve_cache_paths(cache_dir, repo_key)
        snap_dir = File.join(paths["repo_dir"], "snapshots")
        Dir.mkdir_p(snap_dir)

        target = File.join(snap_dir, "#{name}.json")
        tmp = target + ".tmp"
        File.write(tmp, code_graph_to_json(graph))
        File.rename(tmp, target)
      end

      def load_snapshot(name : String, cache_dir : String, repo_key : String = "default") : CodeGraph?
        paths = resolve_cache_paths(cache_dir, repo_key)
        target = File.join(paths["repo_dir"], "snapshots", "#{name}.json")
        return nil unless File.exists?(target)
        code_graph_from_json(File.read(target))
      rescue
        nil
      end

      def list_snapshots(cache_dir : String, repo_key : String = "default") : Array(String)
        paths = resolve_cache_paths(cache_dir, repo_key)
        snap_dir = File.join(paths["repo_dir"], "snapshots")
        return [] of String unless Dir.exists?(snap_dir)
        Dir.children(snap_dir)
          .select { |e| e.ends_with?(".json") }
          .map { |e| e.sub(/\.json$/, "") }
      rescue
        [] of String
      end

      def delete_snapshot(name : String, cache_dir : String, repo_key : String = "default") : Nil
        paths = resolve_cache_paths(cache_dir, repo_key)
        target = File.join(paths["repo_dir"], "snapshots", "#{name}.json")
        File.delete(target) if File.exists?(target)
      rescue
      end

      # --- Private helpers ---

      private def load_manifest(paths : Hash(String, String)) : Hash(String, JSON::Any)
        unless File.exists?(paths["manifest_path"])
          return Hash(String, JSON::Any).new.tap { |h|
            h["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION)
            h["entries"] = JSON.parse(%({}))
          }
        end
        raw = File.read(paths["manifest_path"]) rescue return Hash(String, JSON::Any).new.tap { |h| h["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION); h["entries"] = JSON.parse(%({})) }
        parsed = JSON.parse(raw).as_h
        schema = parsed["schemaVersion"]?
        unless schema && schema.raw.is_a?(String) && schema.raw.as(String) == CACHE_SCHEMA_VERSION
          return Hash(String, JSON::Any).new.tap { |h|
            h["schemaVersion"] = JSON::Any.new(CACHE_SCHEMA_VERSION)
            h["entries"] = JSON.parse(%({}))
          }
        end
        parsed
      end

      private def write_manifest(paths : Hash(String, String), manifest : Hash(String, JSON::Any)) : Nil
        tmp = paths["manifest_path"] + ".tmp"
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
        {
          "defines" => graph.defines.map { |d| {"file" => d.file, "name" => d.name, "kind" => d.kind.to_s, "line" => d.line} },
          "calls"   => graph.calls.map { |c|
            h = {"caller" => c.caller, "callee" => c.callee}
            h = h.merge({"callee_qn" => c.callee_qn.not_nil!}) if c.callee_qn
            h
          },
          "imports"  => graph.imports.map { |i| {"file" => i.file, "name" => i.name, "source" => i.source} },
          "exports"  => graph.exports.map { |e| {"file" => e.file, "name" => e.name} },
          "contains" => graph.contains.map { |c| {"parent" => c.parent, "child" => c.child} },
        }.to_json
      end

      private def code_graph_from_json(raw : String) : CodeGraph
        parsed = JSON.parse(raw)
        CodeGraph.new(
          defines: parsed["defines"].as_a.map { |d|
            DefinesFact.new(file: d["file"].as_s, name: d["name"].as_s, kind: SymbolKind.parse(d["kind"].as_s), line: d["line"].as_i)
          },
          calls: parsed["calls"].as_a.map { |c|
            CallsFact.new(caller: c["caller"].as_s, callee: c["callee"].as_s, callee_qn: c["callee_qn"]?.try(&.as_s?))
          },
          imports: parsed["imports"].as_a.map { |i|
            ImportsFact.new(file: i["file"].as_s, name: i["name"].as_s, source: i["source"].as_s)
          },
          exports: parsed["exports"].as_a.map { |e|
            ExportsFact.new(file: e["file"].as_s, name: e["name"].as_s)
          },
          contains: parsed["contains"].as_a.map { |c|
            ContainsFact.new(parent: c["parent"].as_s, child: c["child"].as_s)
          },
        )
      end

      private def write_manifest(paths : Hash(String, String), manifest : JSON::Any) : Nil
        tmp = paths["manifest_path"] + ".tmp"
        File.write(tmp, manifest.to_json)
        File.rename(tmp, paths["manifest_path"])
      end

      private def evict_if_over_budget(paths : Hash(String, String), manifest : Hash(String, JSON::Any), budget : Int32) : Nil
        entries = manifest["entries"].as_h
        manifest_total = entries.values.sum { |e| e["size"].as_s.to_i }
        return if manifest_total <= budget

        files_dir = paths["files_dir"]
        return unless Dir.exists?(files_dir)

        disk_entries = [] of NamedTuple(name: String, size: Int64, mtime: Time, path: String)
        Dir.children(files_dir).each do |n|
          next unless n.ends_with?(".json")
          p = File.join(files_dir, n)
          begin
            st = File.info(p)
            disk_entries << {name: n, size: st.size, mtime: st.modification_time, path: p}
          rescue
          end
        end

        total = disk_entries.sum(&.[:size]).to_i
        return if total <= budget

        disk_entries.sort_by!(&.[:mtime])

        # Build hash→filePath index
        hash_to_path = Hash(String, String).new
        entries.each { |fp, e| hash_to_path[e["hash"].as_s] = fp }

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
