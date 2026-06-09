# chiasmus_verify tool - Submit formal logic to solver
require "mcp"
require "../../solvers/factory"
require "../../solvers/z3_solver"
require "../../solvers/prolog_cr_solver"
require "../../solvers/prolog_solver"
require "../../graph/mermaid"

module Chiasmus
  module MCPServer
    module Tools
      # Tool definition for chiasmus_verify
      class VerifyTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::VerifyInput.from_json(arguments.to_json)

          spec = args.input || args.spec
          return Types::ErrorResponse.new("Missing required parameters: solver and input/spec") unless spec

          case args.solver
          when "z3"
            result = execute_z3(spec)
            Types::VerifyResponse.new(result: Types.solver_result_to_json(result))
          when "prolog"
            if qs = args.queries
              return Types::ErrorResponse.new("'query' or 'queries' parameter required for prolog solver") if qs.empty?

              results = execute_prolog_batch(normalize_prolog_spec(spec, args.format), qs, args.explain)
              return Types::VerifyResponse.new(results: results.map { |solver_result| Types.solver_result_to_json(solver_result) })
            end

            if query = args.query
              result = execute_prolog(normalize_prolog_spec(spec, args.format), query, args.explain)
              Types::VerifyResponse.new(result: Types.solver_result_to_json(result))
            else
              Types::ErrorResponse.new("Query parameter required for prolog solver")
            end
          else
            Types::ErrorResponse.new("Unknown solver: #{args.solver}")
          end
        rescue ex : JSON::ParseException
          Types::ErrorResponse.new("queries array must contain only strings: #{ex.message}")
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_verify"
        end

        def self.tool_description : String
          <<-DESC
Submit formal logic to solver. Returns verified result.

SOLVERS:
  z3     — SMT-LIB format → SAT + model | UNSAT + unsatCore | error
  prolog — facts/rules + query goal → answers | error

FORMAT (optional, prolog only):
  mermaid — parse Mermaid flowchart/stateDiagram → Prolog facts + reachability rules

DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: {
              "solver" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Solver type: 'z3' or 'prolog'"),
                "enum"        => JSON::Any.new(["z3", "prolog"].map { |v| JSON::Any.new(v) }),
              }),
              "spec" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Formal specification in solver format"),
              }),
              "query" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Query for prolog solver (required for prolog)"),
              }),
              "queries" => JSON::Any.new({
                "type"        => JSON::Any.new("array"),
                "items"       => JSON::Any.new({"type" => JSON::Any.new("string")}),
                "description" => JSON::Any.new("Batch mode: array of Prolog query goals. Runs all against same program."),
              }),
              "explain" => JSON::Any.new({
                "type"        => JSON::Any.new("boolean"),
                "description" => JSON::Any.new("Include derivation trace for prolog"),
              }),
              "format" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Input format: 'raw' or 'mermaid' (prolog only)"),
              }),
            },
            required: ["solver", "spec"]
          )
        end

        def self.normalize_prolog_spec(spec : String, format : String) : String
          case format
          when "raw"
            spec
          when "mermaid"
            Graph::Mermaid.parse(spec)
          else
            raise "Unsupported prolog format: #{format}"
          end
        end

        private def normalize_prolog_spec(spec : String, format : String) : String
          self.class.normalize_prolog_spec(spec, format)
        end

        private def execute_z3(spec : String) : Solvers::SolverResult
          solver_input = Solvers::Z3SolverInput.new(smtlib: spec)
          execute_solver(solver_input)
        end

        private def execute_prolog(spec : String, query : String, explain : Bool) : Solvers::SolverResult
          solver_input = Solvers::PrologSolverInput.new(program: spec, query: query, explain: explain)
          execute_solver(solver_input)
        end

        private def execute_prolog_batch(spec : String, queries : Array(String), explain : Bool) : Array(Solvers::SolverResult)
          solver = Solvers::Factory.build(Solvers::SolverType::Prolog)
          begin
            results = [] of Solvers::SolverResult
            queries.each do |query|
              result = solver.solve(Solvers::PrologSolverInput.new(program: spec, query: query, explain: explain))
              results << result
              break if result.is_a?(Solvers::ErrorResult)
            end
            results
          ensure
            solver.dispose
          end
        end

        private def execute_solver(input : Solvers::SolverInput) : Solvers::SolverResult
          solver = Solvers::Factory.build(input)
          begin
            solver.solve(input)
          ensure
            solver.dispose
          end
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"result":{"type":"object"}})).as_h
          )
        end
      end
    end
  end
end
