require "./extractor"
require "./facts"
require "./ir"
require "./types"
require "./layer_violation"
require "./insights"
require "./community"
require "./diff"
require "./entry_points"

require "tracing"

module Chiasmus
  module Graph
    # Analysis payload that can be properly serialized to JSON
    # Using a tagged union pattern with JSON::Serializable
    alias AnalysisPayload = String | Array(String) | Hash(String, String) | Hash(String, Bool) | Hash(String, Int32) | Hash(String, Array(Array(String)))

    # Tagged union container for JSON serialization
    struct TaggedAnalysisPayload
      include JSON::Serializable

      @[JSON::Field(key: "type", emit_null: false)]
      property type : String

      @[JSON::Field(key: "value")]
      property value : JSON::Any

      def initialize(payload : String | Array(String) | Hash(String, String) | Hash(String, Bool) | Hash(String, Int32) | Hash(String, Array(Array(String))))
        @type, @value = case payload
                        when String
                          {"string", JSON.parse(payload.to_json)}
                        when Array(String)
                          {"array", JSON.parse(payload.to_json)}
                        when Hash(String, String)
                          {"string_hash", JSON.parse(payload.to_json)}
                        when Hash(String, Bool)
                          {"bool_hash", JSON.parse(payload.to_json)}
                        when Hash(String, Int32)
                          {"int_hash", JSON.parse(payload.to_json)}
                        when Hash(String, Array(Array(String)))
                          {"array_array_hash", JSON.parse(payload.to_json)}
                        else
                          {"unknown", JSON.parse(payload.to_s.to_json)}
                        end
      end

      # Convert back to payload
      def to_payload : String | Array(String) | Hash(String, String) | Hash(String, Bool) | Hash(String, Int32) | Hash(String, Array(Array(String)))
        case @type
        when "string"
          @value.as_s
        when "array"
          @value.as_a.map(&.as_s)
        when "string_hash"
          hash = Hash(String, String).new
          @value.as_h.each { |key, value| hash[key] = value.as_s }
          hash
        when "bool_hash"
          hash = Hash(String, Bool).new
          @value.as_h.each { |key, value| hash[key] = value.as_bool }
          hash
        when "int_hash"
          hash = Hash(String, Int32).new
          @value.as_h.each { |key, value| hash[key] = value.as_i }
          hash
        when "array_array_hash"
          hash = Hash(String, Array(Array(String))).new
          @value.as_h.each do |key, value|
            hash[key] = value.as_a.map do |inner|
              inner.as_a.map(&.as_s)
            end
          end
          hash
        else
          @value.to_s
        end
      end
    end

    enum AnalysisType
      Summary
      Callers
      Callees
      Reachability
      DeadCode
      Cycles
      Path
      Impact
      Facts
      LayerViolation
      Hubs
      Bridges
      Surprises
      Community
      Diff
      EntryPoints
    end

    record AnalysisRequest,
      analysis : AnalysisType,
      target : String? = nil,
      from : String? = nil,
      to : String? = nil,
      entry_points : Array(String)? = nil,
      against : String? = nil,
      include_insights : Bool = false

    record AnalysisResult,
      analysis : AnalysisType,
      result : String | Array(String) | Hash(String, String) | Hash(String, Bool) | Hash(String, Int32) | Hash(String, Array(Array(String))) do
      include JSON::Serializable

      # Custom serialization using tagged container
      def to_json(json : JSON::Builder)
        json.object do
          json.field "analysis" do
            json.string(analysis.to_s.downcase)
          end
          json.field "result" do
            TaggedAnalysisPayload.new(result).to_json(json)
          end
        end
      end

      def self.new(pull : JSON::PullParser)
        analysis = AnalysisType::Summary
        tagged_result : TaggedAnalysisPayload? = nil

        pull.read_object do |key|
          case key
          when "analysis"
            analysis = AnalysisType.parse(pull.read_string)
          when "result"
            tagged_result = TaggedAnalysisPayload.from_json(pull)
          else
            pull.skip
          end
        end

        result = tagged_result ? tagged_result.to_payload : ""
        new(analysis: analysis, result: result)
      end
    end

    module Analyses
      extend self

      @@before_async_result_send_hook = nil.as((-> Nil)?)

      record AsyncAnalysisResult,
        value : AnalysisResult? = nil,
        error : String? = nil

      def run_analysis(file_paths : Array(String), request : AnalysisRequest, cache_dir : String? = nil, snapshot_cache_dir : String? = nil, repo_key : String? = nil, max_bytes : Int32? = nil, save_snapshot : String? = nil) : AnalysisResult
        telemetry_span = Tracing.span(Tracing::Level::INFO, "chiasmus.graph.run_analysis", files: file_paths.size, analysis: request.analysis.to_s)
        started_at = Time.instant

        # Guard: save+diff against same snapshot would clobber baseline before diff runs
        if save_snapshot && request.analysis.diff? && request.against == save_snapshot
          telemetry_span.record(guard_rejected: "save_snapshot_equals_against", elapsed_ms: (Time.instant - started_at).total_milliseconds)
          return AnalysisResult.new(
            analysis: request.analysis,
            result: {"error" => "save_snapshot and against cannot name the same snapshot ('#{save_snapshot}') — the save would overwrite the baseline before the diff runs. Use distinct names."}.to_json.as(AnalysisPayload)
          )
        end

        read_started_at = Time.instant
        files = FileIO.read_source_files_or_raise(file_paths)
        read_elapsed_ms = (Time.instant - read_started_at).total_milliseconds
        Tracing.info("chiasmus.graph.run_analysis.read_files", files: file_paths.size, elapsed_ms: read_elapsed_ms)

        extract_started_at = Time.instant
        graph = Extractor.extract_graph(files, cache_dir: cache_dir, repo_key: repo_key, max_bytes: max_bytes)
        extract_elapsed_ms = (Time.instant - extract_started_at).total_milliseconds
        Tracing.info("chiasmus.graph.run_analysis.extract", files: file_paths.size, elapsed_ms: extract_elapsed_ms,
          defines: graph.defines.size, calls: graph.calls.size, imports: graph.imports.size)

        if save_snapshot && cache_dir
          snap_name = save_snapshot
          snap_dir = cache_dir
          snap_repo = repo_key || GraphCache.default_repo_key
          snap_started_at = Time.instant
          GraphCache.save_snapshot_async(snap_name, graph, snap_dir, repo_key: snap_repo)
          snap_elapsed_ms = (Time.instant - snap_started_at).total_milliseconds
          Tracing.info("chiasmus.graph.run_analysis.snapshot_queue", snapshot: snap_name, elapsed_ms: snap_elapsed_ms)
        end

        analysis_started_at = Time.instant
        result = run_analysis_from_graph(graph, request, snapshot_cache_dir: snapshot_cache_dir, repo_key: repo_key)
        analysis_elapsed_ms = (Time.instant - analysis_started_at).total_milliseconds
        Tracing.info("chiasmus.graph.run_analysis.analysis", type: request.analysis.to_s, elapsed_ms: analysis_elapsed_ms)

        total_elapsed_ms = (Time.instant - started_at).total_milliseconds
        telemetry_span.record(
          files: file_paths.size,
          read_ms: read_elapsed_ms,
          extract_ms: extract_elapsed_ms,
          analysis_ms: analysis_elapsed_ms,
          total_ms: total_elapsed_ms,
        )
        result
      end

      def run_analysis_async(
        file_paths : Array(String),
        request : AnalysisRequest,
        cache_dir : String? = nil,
        snapshot_cache_dir : String? = nil,
        repo_key : String? = nil,
        max_bytes : Int32? = nil,
        save_snapshot : String? = nil,
      ) : Channel(AsyncAnalysisResult)
        channel = Channel(AsyncAnalysisResult).new(1)

        spawn do
          begin
            result = run_analysis(
              file_paths,
              request,
              cache_dir: cache_dir,
              snapshot_cache_dir: snapshot_cache_dir,
              repo_key: repo_key,
              max_bytes: max_bytes,
              save_snapshot: save_snapshot
            )
            @@before_async_result_send_hook.try(&.call)
            channel.send(AsyncAnalysisResult.new(value: result))
          rescue ex
            @@before_async_result_send_hook.try(&.call)
            channel.send(AsyncAnalysisResult.new(error: ex.message || ex.class.name))
          ensure
            channel.close
          end
        end

        channel
      end

      def run_analysis_from_graph(graph : CodeGraph, request : AnalysisRequest, snapshot_cache_dir : String? = nil, repo_key : String? = nil) : AnalysisResult
        result = handle_analysis_request(graph, request, snapshot_cache_dir, repo_key)
        AnalysisResult.new(analysis: request.analysis, result: result.as(AnalysisPayload))
      end

      def run_analysis_from_graph(graph : IR::SemanticGraph, request : AnalysisRequest, snapshot_cache_dir : String? = nil, repo_key : String? = nil) : AnalysisResult
        run_analysis_from_graph(IR::Lowering.to_code_graph(graph), request, snapshot_cache_dir: snapshot_cache_dir, repo_key: repo_key)
      end

      def run_analysis_from_graph_async(
        graph : CodeGraph,
        request : AnalysisRequest,
        snapshot_cache_dir : String? = nil,
        repo_key : String? = nil,
      ) : Channel(AsyncAnalysisResult)
        channel = Channel(AsyncAnalysisResult).new(1)

        spawn do
          begin
            result = run_analysis_from_graph(graph, request, snapshot_cache_dir: snapshot_cache_dir, repo_key: repo_key)
            @@before_async_result_send_hook.try(&.call)
            channel.send(AsyncAnalysisResult.new(value: result))
          rescue ex
            @@before_async_result_send_hook.try(&.call)
            channel.send(AsyncAnalysisResult.new(error: ex.message || ex.class.name))
          ensure
            channel.close
          end
        end

        channel
      end

      def run_analysis_from_graph_async(
        graph : IR::SemanticGraph,
        request : AnalysisRequest,
        snapshot_cache_dir : String? = nil,
        repo_key : String? = nil,
      ) : Channel(AsyncAnalysisResult)
        run_analysis_from_graph_async(
          IR::Lowering.to_code_graph(graph),
          request,
          snapshot_cache_dir: snapshot_cache_dir,
          repo_key: repo_key
        )
      end

      def set_before_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_async_result_send_hook = block
      end

      def clear_before_async_result_send_hook_for_test : Nil
        @@before_async_result_send_hook = nil
      end

      private def handle_analysis_request(graph : CodeGraph, request : AnalysisRequest, snapshot_cache_dir : String? = nil, repo_key : String? = nil)
        case request.analysis
        when AnalysisType::Facts
          Facts.graph_to_prolog(graph, request.entry_points, request.include_insights)
        when AnalysisType::Summary
          build_summary(graph)
        when AnalysisType::Callers
          handle_target_analysis(graph, request.target, :callers)
        when AnalysisType::Callees
          handle_target_analysis(graph, request.target, :callees)
        when AnalysisType::Reachability
          handle_reachability(graph, request.from, request.to)
        when AnalysisType::DeadCode
          dead_code(graph, request.entry_points)
        when AnalysisType::Cycles
          cycle_nodes(graph)
        when AnalysisType::Path
          handle_path(graph, request.from, request.to)
        when AnalysisType::Impact
          handle_target_analysis(graph, request.target, :impact)
        when AnalysisType::Diff
          handle_diff(graph, request.against, snapshot_cache_dir, repo_key)
        when AnalysisType::LayerViolation
          LayerViolation.find(graph).map { |violation| {
            "caller" => violation.caller, "callee" => violation.callee,
            "caller_layer" => violation.caller_layer, "callee_layer" => violation.callee_layer,
          } }.to_json
        when AnalysisType::Hubs
          Insights.detect_hubs(graph).map { |hub| {"name" => hub.name, "degree" => hub.degree.to_s} }.to_json
        when AnalysisType::Bridges
          Insights.detect_bridges(graph).map { |bridge| {"name" => bridge.name, "score" => bridge.score.to_s} }.to_json
        when AnalysisType::Surprises
          Insights.detect_surprises(graph).map { |surprise| {"source" => surprise.source, "target" => surprise.target, "score" => surprise.score, "reasons" => surprise.reasons.join(",")} }.to_json
        when AnalysisType::Community
          CommunityDetection.detect(graph).map { |community| {
            "id" => community.id, "members" => community.members, "cohesion" => community.cohesion,
          } }.to_json
        when AnalysisType::EntryPoints
          EntryPoints.detect(graph)
        else
          {"error" => "Unknown analysis type"}.to_json
        end
      end

      private def handle_diff(graph : CodeGraph, against_name : String?, snapshot_cache_dir : String?, repo_key : String? = nil) : String
        return {"error" => "diff requires a snapshot name"}.to_json unless against_name
        return {"error" => "diff requires a cache directory to load snapshots"}.to_json unless snapshot_cache_dir

        before = GraphCache.load_snapshot(against_name, snapshot_cache_dir, repo_key: repo_key || GraphCache.default_repo_key)
        return {"error" => "snapshot '#{against_name}' not found in #{snapshot_cache_dir}"}.to_json unless before

        diff_result = GraphDiffer.diff(before, graph)
        {
          "added_nodes"     => diff_result.added_nodes,
          "removed_nodes"   => diff_result.removed_nodes,
          "added_edges"     => diff_result.added_edges.map { |edge| {"source" => edge.source, "target" => edge.target} },
          "removed_edges"   => diff_result.removed_edges.map { |edge| {"source" => edge.source, "target" => edge.target} },
          "added_imports"   => diff_result.added_imports.size,
          "removed_imports" => diff_result.removed_imports.size,
          "added_exports"   => diff_result.added_exports.size,
          "removed_exports" => diff_result.removed_exports.size,
          "summary"         => diff_result.summary,
        }.to_json
      end

      private def handle_target_analysis(graph : CodeGraph, target : String?, analysis_type : Symbol)
        return missing_parameter_result unless target

        case analysis_type
        when :callers
          callers(graph, target)
        when :callees
          callees(graph, target)
        when :impact
          impact(graph, target)
        else
          missing_parameter_result
        end
      end

      private def handle_reachability(graph : CodeGraph, from : String?, to : String?)
        if from && to
          {"reachable" => reachable?(graph, from, to)}
        else
          missing_parameter_result
        end
      end

      private def handle_path(graph : CodeGraph, from : String?, to : String?)
        if from && to
          build_path_result(path_between(graph, from, to))
        else
          missing_parameter_result
        end
      end

      private def build_summary(graph : CodeGraph) : Hash(String, Int32)
        {
          "files"     => graph.defines.map(&.file).uniq!.size,
          "functions" => graph.defines.count { |fact| fact.kind.function? || fact.kind.method? },
          "classes"   => graph.defines.count(&.kind.class?),
          "callEdges" => graph.calls.size,
          "imports"   => graph.imports.size,
          "exports"   => graph.exports.size,
        }
      end

      private def missing_parameter_result : Hash(String, String)
        {"error" => "Missing required parameters"}
      end

      private def callers(graph : CodeGraph, target : String) : Array(String)
        graph.calls.select { |fact| fact.callee == target }.map(&.caller).uniq!
      end

      private def callees(graph : CodeGraph, source : String) : Array(String)
        graph.calls.select { |fact| fact.caller == source }.map(&.callee).uniq!
      end

      private def dead_code(graph : CodeGraph, entry_points : Array(String)?) : Array(String)
        called = graph.calls.map(&.callee).to_set
        roots = (entry_points || graph.exports.map(&.name)).to_set

        names = [] of String
        seen = Set(String).new

        graph.defines.each do |fact|
          next unless fact.kind.function?
          next if called.includes?(fact.name)
          next if roots.includes?(fact.name)
          next if seen.includes?(fact.name)

          names << fact.name
          seen.add(fact.name)
        end

        names
      end

      private def cycle_nodes(graph : CodeGraph) : Array(String)
        adjacency = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
        graph.calls.each do |fact|
          adjacency[fact.caller_qn || fact.caller].add(fact.callee_qn || fact.callee)
        end
        nodes = [] of String

        adjacency.keys.each do |node|
          nodes << node if reaches_target?(adjacency, node, node, require_edge: true)
        end

        nodes
      end

      private def impact(graph : CodeGraph, target : String) : Array(String)
        reverse = reverse_adjacency_map(graph)
        queue = Deque(String).new
        seen = Set(String).new
        affected = [] of String

        reverse[target]?.try do |parents|
          parents.each { |parent| queue << parent }
        end

        until queue.empty?
          current = queue.shift
          next if seen.includes?(current)

          seen << current
          affected << current

          reverse[current]?.try do |parents|
            parents.each do |parent|
              queue << parent unless seen.includes?(parent)
            end
          end
        end

        affected
      end

      private def path_between(graph : CodeGraph, source : String, target : String) : Array(String)?
        adjacency = adjacency_map(graph)
        queue = Deque(Array(String)).new
        queue << [source]
        seen = Set(String).new
        seen << source

        until queue.empty?
          path = queue.shift
          current = path.last
          return path if current == target

          adjacency[current]?.try do |neighbors|
            neighbors.each do |neighbor|
              next if seen.includes?(neighbor)

              seen << neighbor
              queue << (path + [neighbor])
            end
          end
        end

        nil
      end

      private def build_path_result(path : Array(String)?) : Hash(String, Array(Array(String)))
        {"paths" => path ? [path] : [] of Array(String)}
      end

      private def reachable?(graph : CodeGraph, source : String, target : String) : Bool
        reaches_target?(adjacency_map(graph), source, target, require_edge: false)
      end

      private def reaches_target?(adjacency : Hash(String, Set(String)), source : String, target : String, *, require_edge : Bool) : Bool
        queue = Deque(String).new
        seen = Set(String).new

        if require_edge
          adjacency[source]?.try do |neighbors|
            neighbors.each { |neighbor| queue << neighbor }
          end
        else
          queue << source
        end

        until queue.empty?
          current = queue.shift
          return true if current == target
          next if seen.includes?(current)

          seen << current
          adjacency[current]?.try do |neighbors|
            neighbors.each do |neighbor|
              queue << neighbor unless seen.includes?(neighbor)
            end
          end
        end

        false
      end

      private def adjacency_map(graph : CodeGraph) : Hash(String, Set(String))
        graph.calls.each_with_object(Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }) do |fact, memo|
          memo[fact.caller] << fact.callee
          memo[fact.callee] ||= Set(String).new
        end
      end

      private def reverse_adjacency_map(graph : CodeGraph) : Hash(String, Set(String))
        graph.calls.each_with_object(Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }) do |fact, memo|
          memo[fact.callee] << fact.caller
          memo[fact.caller] ||= Set(String).new
        end
      end
    end
  end
end
