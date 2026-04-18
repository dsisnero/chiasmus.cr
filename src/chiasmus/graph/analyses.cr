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
          @value.as_h.each { |k, v| hash[k] = v.as_s }
          hash
        when "bool_hash"
          hash = Hash(String, Bool).new
          @value.as_h.each { |k, v| hash[k] = v.as_bool }
          hash
        when "int_hash"
          hash = Hash(String, Int32).new
          @value.as_h.each { |k, v| hash[k] = v.as_i }
          hash

        when "array_array_hash"
          hash = Hash(String, Array(Array(String))).new
          @value.as_h.each do |k, v|
            hash[k] = v.as_a.map do |inner|
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
    end

    record AnalysisRequest,
      analysis : AnalysisType,
      target : String? = nil,
      from : String? = nil,
      to : String? = nil,
      entry_points : Array(String)? = nil

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

        result = tagged_result ? tagged_result.not_nil!.to_payload : ""
        new(analysis: analysis, result: result)
      end
    end

    module Analyses
      extend self

      def run_analysis(file_paths : Array(String), request : AnalysisRequest) : AnalysisResult
        files = file_paths.map do |path|
          SourceFile.new(path: path, content: File.read(path))
        end

        run_analysis_from_graph(Extractor.extract_graph(files), request)
      end

      def run_analysis_from_graph(graph : CodeGraph, request : AnalysisRequest) : AnalysisResult
        result = handle_analysis_request(graph, request)
        AnalysisResult.new(analysis: request.analysis, result: result.as(AnalysisPayload))
      end

      private def handle_analysis_request(graph : CodeGraph, request : AnalysisRequest)
        case request.analysis
        when AnalysisType::Facts
          Facts.graph_to_prolog(graph, request.entry_points)
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
        else
          missing_parameter_result
        end
      end

      private def handle_target_analysis(graph : CodeGraph, target : String?, analysis_type : Symbol)
        return missing_parameter_result unless target

        case analysis_type
        when :callers
          callers(graph, target.not_nil!)
        when :callees
          callees(graph, target.not_nil!)
        when :impact
          impact(graph, target.not_nil!)
        else
          missing_parameter_result
        end
      end

      private def handle_reachability(graph : CodeGraph, from : String?, to : String?)
        if from && to
          {"reachable" => reachable?(graph, from.not_nil!, to.not_nil!)}
        else
          missing_parameter_result
        end
      end

      private def handle_path(graph : CodeGraph, from : String?, to : String?)
        if from && to
          build_path_result(path_between(graph, from.not_nil!, to.not_nil!))
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
        adjacency = adjacency_map(graph)
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
