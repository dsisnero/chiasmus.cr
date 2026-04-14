module Chiasmus
  module Graph
    alias AnalysisPayload = Array(String) | String | Hash(String, String) | Hash(String, Bool) | Hash(String, Int32) | Hash(String, Array(String)) | Hash(String, Array(Array(String)))

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
      result : AnalysisPayload

    module Analyses
      extend self

      def run_analysis(file_paths : Array(String), request : AnalysisRequest) : AnalysisResult
        files = file_paths.map do |path|
          SourceFile.new(path: path, content: File.read(path))
        end

        run_analysis_from_graph(Extractor.extract_graph(files), request)
      end

      def run_analysis_from_graph(graph : CodeGraph, request : AnalysisRequest) : AnalysisResult
        result = case request.analysis
                 when AnalysisType::Facts
                   Facts.graph_to_prolog(graph, request.entry_points)
                 when AnalysisType::Summary
                   build_summary(graph)
                 when AnalysisType::Callers
                   request.target ? callers(graph, request.target.not_nil!) : missing_parameter_result
                 when AnalysisType::Callees
                   request.target ? callees(graph, request.target.not_nil!) : missing_parameter_result
                 when AnalysisType::Reachability
                   if request.from && request.to
                     {"reachable" => reachable?(graph, request.from.not_nil!, request.to.not_nil!)}
                   else
                     missing_parameter_result
                   end
                 when AnalysisType::DeadCode
                   dead_code(graph, request.entry_points)
                 when AnalysisType::Cycles
                   cycle_nodes(graph)
                 when AnalysisType::Path
                   if request.from && request.to
                     build_path_result(path_between(graph, request.from.not_nil!, request.to.not_nil!))
                   else
                     missing_parameter_result
                   end
                 when AnalysisType::Impact
                   request.target ? impact(graph, request.target.not_nil!) : missing_parameter_result
                 else
                   missing_parameter_result
                 end

        AnalysisResult.new(analysis: request.analysis, result: result)
      end

      private def build_summary(graph : CodeGraph) : Hash(String, Int32)
        {
          "files"     => graph.defines.map(&.file).uniq.size,
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
        graph.calls.select { |fact| fact.callee == target }.map(&.caller).uniq
      end

      private def callees(graph : CodeGraph, source : String) : Array(String)
        graph.calls.select { |fact| fact.caller == source }.map(&.callee).uniq
      end

      private def dead_code(graph : CodeGraph, entry_points : Array(String)?) : Array(String)
        called = graph.calls.map(&.callee).to_set
        roots = (entry_points || graph.exports.map(&.name)).to_set

        names = [] of String
        graph.defines.each do |fact|
          next unless fact.kind.function?
          next if called.includes?(fact.name)
          next if roots.includes?(fact.name)
          next if names.includes?(fact.name)

          names << fact.name
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

      private def reaches_target?(adjacency : Hash(String, Array(String)), source : String, target : String, *, require_edge : Bool) : Bool
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

      private def adjacency_map(graph : CodeGraph) : Hash(String, Array(String))
        graph.calls.each_with_object(Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }) do |fact, memo|
          neighbors = memo[fact.caller]
          neighbors << fact.callee unless neighbors.includes?(fact.callee)
          memo[fact.callee] ||= [] of String
        end
      end

      private def reverse_adjacency_map(graph : CodeGraph) : Hash(String, Array(String))
        graph.calls.each_with_object(Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }) do |fact, memo|
          parents = memo[fact.callee]
          parents << fact.caller unless parents.includes?(fact.caller)
          memo[fact.caller] ||= [] of String
        end
      end
    end
  end
end
