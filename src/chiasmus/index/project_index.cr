require "../graph/types"
require "../graph/extractor"
require "../utils/bounded_work"
require "./file_discovery"

module Chiasmus
  module Index
    # Immutable read model derived from per-file CodeGraphs.
    #
    # A ProjectIndex actor owns the current snapshot and serializes file
    # replacement/removal. Consumers must treat the returned facts and graph as
    # read-only; every update publishes newly allocated collections.
    record ProjectIndexSnapshot,
      generation : Int64,
      graph : Graph::CodeGraph,
      definitions_by_name : Hash(String, Array(Graph::DefinesFact)),
      definitions_by_file : Hash(String, Array(Graph::DefinesFact)),
      callers_by_callee : Hash(String, Array(Graph::CallsFact)),
      callees_by_caller : Hash(String, Array(Graph::CallsFact)),
      imports_by_file : Hash(String, Array(Graph::ImportsFact)),
      exports_by_file : Hash(String, Set(String)),
      files_by_path : Hash(String, Graph::FileNode),
      graphs_by_file : Hash(String, Graph::CodeGraph),
      fingerprints : Hash(String, FileFingerprint)

    record FileFingerprint, size : Int64, modified_at_ns : Int64
    record ProjectIndexLookup, graph : Graph::CodeGraph?, status : String

    class ProjectIndex
      private record SnapshotRequest, reply : Channel(ProjectIndexSnapshot)
      private record UpsertRequest, graph : Graph::CodeGraph, reply : Channel(Bool)
      private record UpsertManyRequest, graphs : Array(Graph::CodeGraph), reply : Channel(Bool)
      private record RemoveRequest, path : String, reply : Channel(Bool)
      private record CloseRequest, reply : Channel(Bool)

      private alias Request = SnapshotRequest | UpsertRequest | UpsertManyRequest | RemoveRequest | CloseRequest

      @requests = Channel(Request).new
      @closed = Atomic(Bool).new(false)

      def initialize(graphs : Enumerable(Graph::CodeGraph) = [] of Graph::CodeGraph)
        initial = {} of String => Graph::CodeGraph
        graphs.each do |graph|
          if path = graph_file_path(graph)
            initial[path] = graph
          end
        end
        start_actor(initial)
      end

      def snapshot : ProjectIndexSnapshot
        reply = Channel(ProjectIndexSnapshot).new(1)
        @requests.send(SnapshotRequest.new(reply))
        reply.receive
      end

      def graph : Graph::CodeGraph
        snapshot.graph
      end

      def covers?(paths : Array(String)) : Bool
        indexed = snapshot.graphs_by_file
        paths.all? { |path| indexed.has_key?(path) }
      end

      # Return a graph containing exactly the requested indexed files.
      def graph_for(paths : Array(String)) : Graph::CodeGraph?
        lookup(paths).graph
      end

      def lookup(paths : Array(String)) : ProjectIndexLookup
        state = snapshot
        return ProjectIndexLookup.new(nil, "miss") unless paths.all? { |path| state.graphs_by_file.has_key?(path) }
        fresh = paths.all? do |path|
          expected = state.fingerprints[path]?
          expected.nil? || expected == file_fingerprint(path)
        end
        return ProjectIndexLookup.new(nil, "stale") unless fresh
        ProjectIndexLookup.new(build_snapshot(paths.to_h { |path| {path, state.graphs_by_file[path]} }, state.generation).graph, "resident_hit")
      end

      # Populate missing files concurrently, then return a graph containing
      # exactly `paths`. The watcher keeps already-indexed files fresh.
      def ensure_files_async(
        paths : Array(String),
        cache_dir : String? = nil,
        repo_key : String? = nil,
        max_concurrent : Int32 = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT,
      ) : Channel(Graph::CodeGraph?)
        result = Channel(Graph::CodeGraph?).new(1)
        spawn do
          state = snapshot
          missing = paths.reject { |path| state.graphs_by_file.has_key?(path) }
          extracted = Utils::BoundedWork.map_ordered(missing, max_concurrent) do |path|
            if !closed? && File.exists?(path)
              Graph::Extractor.extract_and_cache_file(path, cache_dir: cache_dir, repo_key: repo_key)
            end
          end
          extracted.compact_map(&.itself).each { |file_graph| upsert_file(file_graph) unless closed? }
          result.send(closed? ? nil : graph_for(paths))
          result.close
        end
        result
      end

      # Warm the resident index without delaying MCP transport startup. Git's
      # tracked/untracked file list supplies ignore semantics and avoids walking
      # dependency/build directories that are not part of the project.
      def warm_root_async(
        root : String,
        cache_dir : String? = nil,
        repo_key : String? = nil,
      ) : Channel(Int32)
        result = Channel(Int32).new(1)
        spawn do
          paths = source_paths(root)
          sources = Graph::FileIO.read_source_files_parallel(paths)
          graph = Graph::Extractor.extract_graph_async(
            sources,
            cache_dir: cache_dir,
            repo_key: repo_key,
          ).receive
          upsert_graph(graph)
          result.send(graph.files.try(&.size) || 0)
          result.close
        end
        result
      end

      def definitions_named(name : String) : Array(Graph::DefinesFact)
        snapshot.definitions_by_name[name]? || [] of Graph::DefinesFact
      end

      def definitions_in_file(path : String) : Array(Graph::DefinesFact)
        snapshot.definitions_by_file[path]? || [] of Graph::DefinesFact
      end

      def callers_of(name : String) : Array(Graph::CallsFact)
        snapshot.callers_by_callee[name]? || [] of Graph::CallsFact
      end

      def callees_of(name : String) : Array(Graph::CallsFact)
        snapshot.callees_by_caller[name]? || [] of Graph::CallsFact
      end

      def upsert_file(graph : Graph::CodeGraph) : Bool
        reply = Channel(Bool).new(1)
        @requests.send(UpsertRequest.new(graph, reply))
        reply.receive
      end

      def upsert_files(graphs : Array(Graph::CodeGraph)) : Bool
        reply = Channel(Bool).new(1)
        @requests.send(UpsertManyRequest.new(graphs, reply))
        reply.receive
      end

      # Partition a project graph back into per-file contributions. Calls are
      # assigned through their caller definition; this matches the graph's
      # existing name-based call identity.
      def upsert_graph(graph : Graph::CodeGraph) : Nil
        file_nodes = graph.files || [] of Graph::FileNode
        caller_files = graph.defines.to_h { |fact| {fact.name, fact.file} }
        definitions_by_file = graph.defines.group_by(&.file)
        calls_by_file = graph.calls.group_by { |fact| caller_files[fact.caller]? || "" }
        imports_by_file = graph.imports.group_by(&.file)
        exports_by_file = graph.exports.group_by(&.file)
        type_info_by_file = graph.type_info.try(&.group_by(&.file)) || {} of String => Array(Graph::FileTypeInfo)
        parent_files = graph.defines.to_h { |fact| {fact.name, fact.file} }
        contains_by_file = graph.contains.group_by { |fact| parent_files[fact.parent]? || "" }

        graphs = file_nodes.map do |file_node|
          path = file_node.path
          Graph::CodeGraph.new(
            defines: definitions_by_file[path]? || [] of Graph::DefinesFact,
            calls: calls_by_file[path]? || [] of Graph::CallsFact,
            imports: imports_by_file[path]? || [] of Graph::ImportsFact,
            exports: exports_by_file[path]? || [] of Graph::ExportsFact,
            contains: contains_by_file[path]? || [] of Graph::ContainsFact,
            files: [file_node],
            type_info: type_info_by_file[path]?,
          )
        end
        upsert_files(graphs)
      end

      def remove_file(path : String) : Bool
        reply = Channel(Bool).new(1)
        @requests.send(RemoveRequest.new(path, reply))
        reply.receive
      end

      def close : Nil
        return if closed?
        reply = Channel(Bool).new(1)
        @requests.send(CloseRequest.new(reply))
        reply.receive
        @closed.set(true)
        @requests.close
      rescue Channel::ClosedError
        @closed.set(true)
      end

      def closed? : Bool
        @closed.get
      end

      private def start_actor(initial : Hash(String, Graph::CodeGraph)) : Nil
        spawn do
          per_file = initial
          generation = 0_i64
          current = build_snapshot(per_file, generation)

          while request = @requests.receive?
            case request
            when SnapshotRequest
              request.reply.send(current)
            when UpsertRequest
              if path = graph_file_path(request.graph)
                per_file[path] = request.graph
                generation += 1
                current = build_snapshot(per_file, generation)
                request.reply.send(true)
              else
                request.reply.send(false)
              end
            when UpsertManyRequest
              request.graphs.each do |graph|
                if path = graph_file_path(graph)
                  per_file[path] = graph
                end
              end
              generation += 1
              current = build_snapshot(per_file, generation)
              request.reply.send(true)
            when RemoveRequest
              removed = !per_file.delete(request.path).nil?
              if removed
                generation += 1
                current = build_snapshot(per_file, generation)
              end
              request.reply.send(removed)
            when CloseRequest
              request.reply.send(true)
              break
            end
          end
        end
      end

      private def graph_file_path(graph : Graph::CodeGraph) : String?
        graph.files.try(&.first?).try(&.path) || graph.defines.first?.try(&.file)
      end

      private def file_fingerprint(path : String) : FileFingerprint?
        info = File.info?(path)
        return nil unless info && info.file?
        modified = info.modification_time
        FileFingerprint.new(info.size, modified.to_unix * 1_000_000_000_i64 + modified.nanosecond)
      rescue
        nil
      end

      private def source_paths(root : String) : Array(String)
        FileDiscovery.paths(root)
      end

      private def build_snapshot(per_file : Hash(String, Graph::CodeGraph), generation : Int64 = 0_i64) : ProjectIndexSnapshot
        defines = [] of Graph::DefinesFact
        calls = [] of Graph::CallsFact
        imports = [] of Graph::ImportsFact
        exports = [] of Graph::ExportsFact
        contains = [] of Graph::ContainsFact
        files = [] of Graph::FileNode
        type_info = [] of Graph::FileTypeInfo

        definitions_by_name = Hash(String, Array(Graph::DefinesFact)).new { |h, k| h[k] = [] of Graph::DefinesFact }
        definitions_by_file = Hash(String, Array(Graph::DefinesFact)).new { |h, k| h[k] = [] of Graph::DefinesFact }
        callers_by_callee = Hash(String, Array(Graph::CallsFact)).new { |h, k| h[k] = [] of Graph::CallsFact }
        callees_by_caller = Hash(String, Array(Graph::CallsFact)).new { |h, k| h[k] = [] of Graph::CallsFact }
        imports_by_file = Hash(String, Array(Graph::ImportsFact)).new { |h, k| h[k] = [] of Graph::ImportsFact }
        exports_by_file = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
        files_by_path = {} of String => Graph::FileNode
        fingerprints = {} of String => FileFingerprint

        per_file.keys.sort!.each do |path|
          file_graph = per_file[path]
          if fingerprint = file_fingerprint(path)
            fingerprints[path] = fingerprint
          end
          file_graph.defines.each do |fact|
            defines << fact
            definitions_by_name[fact.name] << fact
            definitions_by_file[fact.file] << fact
          end
          file_graph.calls.each do |fact|
            calls << fact
            callers_by_callee[fact.callee] << fact
            callees_by_caller[fact.caller] << fact
          end
          file_graph.imports.each do |fact|
            imports << fact
            imports_by_file[fact.file] << fact
          end
          file_graph.exports.each do |fact|
            exports << fact
            exports_by_file[fact.file] << fact.name
          end
          contains.concat(file_graph.contains)
          file_graph.files.try &.each do |file|
            files << file
            files_by_path[file.path] = file
          end
          file_graph.type_info.try { |items| type_info.concat(items) }
        end

        ProjectIndexSnapshot.new(
          generation: generation,
          graph: Graph::CodeGraph.new(
            defines: defines,
            calls: calls,
            imports: imports,
            exports: exports,
            contains: contains,
            files: files,
            type_info: type_info.empty? ? nil : type_info,
          ),
          definitions_by_name: definitions_by_name,
          definitions_by_file: definitions_by_file,
          callers_by_callee: callers_by_callee,
          callees_by_caller: callees_by_caller,
          imports_by_file: imports_by_file,
          exports_by_file: exports_by_file,
          files_by_path: files_by_path,
          graphs_by_file: per_file.dup,
          fingerprints: fingerprints,
        )
      end
    end
  end
end
