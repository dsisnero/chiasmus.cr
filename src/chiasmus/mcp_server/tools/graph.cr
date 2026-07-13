# chiasmus_graph tool - Analyze source code call graphs via tree-sitter + Prolog
require "mcp"
require "../types"
require "../tool_schemas"
require "../../graph/analyses"
require "tracing"

module Chiasmus
  module MCPServer
    module Tools
      class GraphTool
        def initialize(@project_index : Index::ProjectIndex? = nil)
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::GraphInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("Missing required parameters: files and analysis") unless args.files && args.analysis

          absolute_files = args.files.map { |file_path| File.expand_path(file_path) }

          unless Graph::AnalysisType.parse?(args.analysis)
            return Types::ErrorResponse.new("Unknown analysis: #{args.analysis}. Use one of: #{VALID_ANALYSES.join(", ")}")
          end

          analysis_type = Graph::AnalysisType.parse(args.analysis)

          request = Graph::AnalysisRequest.new(
            analysis: analysis_type,
            target: args.target,
            from: args.from,
            to: args.to,
            entry_points: args.entry_points,
            against: args.against,
            include_insights: args.include_insights?
          )

          cache_dir = args.cache.try(&.cache_dir) || Graph::GraphCache.default_cache_dir
          repo_key = args.cache.try(&.repo_key)
          max_bytes = args.cache.try(&.max_bytes_per_repo)
          result = run_indexed_analysis(absolute_files, request, cache_dir, repo_key, max_bytes, args.save_snapshot)

          if error = result.error
            return Types::ErrorResponse.new(error)
          end

          result_value_payload = result.value || return Types::ErrorResponse.new("Graph analysis returned no result")

          result_value = if args.analysis == "facts"
                           result_value_payload.result.as(String)
                         else
                           result_value_payload.to_json
                         end

          Types::GraphResponse.new(
            analysis: args.analysis,
            result: JSON::Any.new(result_value)
          )
        rescue ex : File::NotFoundError
          Types::ErrorResponse.new("File not found: #{ex.message}")
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        private def run_indexed_analysis(
          files : Array(String),
          request : Graph::AnalysisRequest,
          cache_dir : String?,
          repo_key : String?,
          max_bytes : Int32?,
          save_snapshot : String?,
        ) : Graph::Analyses::AsyncAnalysisResult
          index = @project_index
          return run_extracted_analysis(files, request, cache_dir, repo_key, max_bytes, save_snapshot) unless index
          return run_extracted_analysis(files, request, cache_dir, repo_key, max_bytes, save_snapshot) if save_snapshot

          lookup = index.lookup(files)
          graph = lookup.graph
          Tracing.info("chiasmus.graph.cache", cache_status: lookup.status, files: files.size)
          return run_and_index_analysis(index, files, request, cache_dir, repo_key, max_bytes) unless graph

          started_at = Time.instant
          value = Graph::Analyses.run_analysis_from_graph(
            graph,
            request,
            snapshot_cache_dir: cache_dir,
            repo_key: repo_key,
          )
          Tracing.info(
            "chiasmus.graph.analysis",
            analysis: request.analysis.to_s,
            analysis_ms: (Time.instant - started_at).total_milliseconds,
          )
          Graph::Analyses::AsyncAnalysisResult.new(value: value)
        end

        private def run_and_index_analysis(
          index : Index::ProjectIndex,
          files : Array(String),
          request : Graph::AnalysisRequest,
          cache_dir : String?,
          repo_key : String?,
          max_bytes : Int32?,
        ) : Graph::Analyses::AsyncAnalysisResult
          source_files = Graph::FileIO.read_source_files_or_raise(files)
          graph = Graph::Extractor.extract_graph_async(
            source_files,
            cache_dir: cache_dir,
            repo_key: repo_key,
            max_bytes: max_bytes,
          ).receive
          index.upsert_graph(graph)
          started_at = Time.instant
          value = Graph::Analyses.run_analysis_from_graph(
            graph,
            request,
            snapshot_cache_dir: cache_dir,
            repo_key: repo_key,
          )
          Tracing.info(
            "chiasmus.graph.analysis",
            analysis: request.analysis.to_s,
            analysis_ms: (Time.instant - started_at).total_milliseconds,
          )
          Graph::Analyses::AsyncAnalysisResult.new(value: value)
        rescue ex
          Graph::Analyses::AsyncAnalysisResult.new(error: ex.message || ex.class.name)
        end

        private def run_extracted_analysis(
          files : Array(String),
          request : Graph::AnalysisRequest,
          cache_dir : String?,
          repo_key : String?,
          max_bytes : Int32?,
          save_snapshot : String?,
        ) : Graph::Analyses::AsyncAnalysisResult
          result = Graph::Analyses.run_analysis_async(
            files,
            request,
            cache_dir: cache_dir,
            snapshot_cache_dir: cache_dir,
            repo_key: repo_key,
            max_bytes: max_bytes,
            save_snapshot: save_snapshot
          ).receive
          # Analyses deliberately persists asynchronously. At the MCP tool
          # boundary, make a named snapshot observable before returning so an
          # immediate follow-up diff cannot race the writer.
          Graph::GraphCache.flush_async_writes if save_snapshot && cache_dir
          result
        end

        def self.tool_name : String
          "chiasmus_graph"
        end

        def self.tool_description : String
          <<-DESC
          Analyze source code call graphs via tree-sitter + native O(V+E) algorithms.

          Parse source files → extract call graph → run formal analysis.
          Dedicated walkers: Crystal, TypeScript, JavaScript, Python, Go, Rust, Java,
          C#, C++, C, Kotlin, Scala, Dart, PHP, Perl, Bash, Protobuf, Clojure.
          Generic tree-sitter fallback for 35+ additional languages.
          Files must be absolute paths. Extraction runs concurrently across files.

          ANALYSES:
            summary         — overview: files, functions, call edges
            callers         — who calls target? (needs target)
            callees         — what does target call? (needs target)
            reachability    — can from reach to? (needs from, to)
            dead-code       — functions unreachable from entry points
            cycles          — circular call dependencies
            path            — call chain from→to (needs from, to)
            impact          — what breaks if target changes? (needs target)
            layer-violation — calls skipping architectural layers
            hubs            — top-degree nodes
            bridges         — betweenness centrality top-3
            surprises       — cross-community + peripheral-to-hub edges
            community       — Louvain community detection (seed=42)
            diff            — compare current graph vs saved snapshot (needs snapshot)
            entry-points    — heuristic entry point detection
            facts           — raw Prolog facts for custom queries via chiasmus_verify
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "files"            => ToolSchemas::Common.files_property,
              "analysis"         => ToolSchemas::Common.analysis_property,
              "target"           => ToolSchemas::Common.target_property,
              "from"             => ToolSchemas::Common.from_property,
              "to"               => ToolSchemas::Common.to_property,
              "entry_points"     => ToolSchemas::Common.entry_points_property,
              "against"          => ToolSchemas::SchemaProperty.new("string", "Snapshot name to diff against (required for diff analysis)"),
              "cache"            => ToolSchemas::SchemaProperty.new("object", "Cache options for per-file extraction cache and snapshot persistence. Supply {cache_dir, repo_key, max_bytes_per_repo}."),
              "save_snapshot"    => ToolSchemas::SchemaProperty.new("string", "Save the extracted graph under this snapshot name after analysis (requires cache)"),
              "include_insights" => ToolSchemas::SchemaProperty.new("boolean", "For analysis=facts: also emit community/2, cohesion/2, hub/2, bridge/2 facts"),
            },
            required: ["files", "analysis"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"analysis":{"type":"string"},"result":{"type":"object"}})).as_h
          )
        end
      end
    end
  end
end
