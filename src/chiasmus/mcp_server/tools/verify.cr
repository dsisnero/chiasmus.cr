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
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          solver = arguments["solver"]?.try(&.as_s?)
          spec = arguments["input"]?.try(&.as_s?) || arguments["spec"]?.try(&.as_s?)
          query = arguments["query"]?.try(&.as_s?)
          queries = arguments["queries"]?
          explain = arguments["explain"]?.try(&.as_bool) || false
          format = arguments["format"]?.try(&.as_s?) || "raw"

          unless solver && spec
            return error_hash("Missing required parameters: solver and input/spec")
          end

          case solver
          when "z3"
            success_hash(run_z3(spec))
          when "prolog"
            return error_hash("queries array is not supported yet") if queries
            return error_hash("Query parameter required for prolog solver") unless query

            success_hash(run_prolog(normalize_prolog_spec(spec, format), query, explain))
          else
            error_hash("Unknown solver: #{solver}")
          end
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
                "enum"        => JSON::Any.new(["z3", "prolog"]),
              }),
              "spec" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Formal specification in solver format"),
              }),
              "query" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Query for prolog solver (required for prolog)"),
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

        def self.call(request : MCP::Protocol::CallToolRequestParams) : MCP::Protocol::CallToolResult
          solver = request.arguments["solver"]?.try(&.as_s)
          spec = request.arguments["spec"]?.try(&.as_s)
          query = request.arguments["query"]?.try(&.as_s)
          explain = request.arguments["explain"]?.try(&.as_bool) || false
          format = request.arguments["format"]?.try(&.as_s) || "raw"

          unless solver && spec
            return error_result("Missing required parameters: solver and spec")
          end

          case solver
          when "z3"
            handle_z3(spec)
          when "prolog"
            handle_prolog(spec, query, explain, format)
          else
            error_result("Unknown solver: #{solver}. Must be 'z3' or 'prolog'")
          end
        rescue ex
          error_result("Error processing request: #{ex.message}")
        end

        private def self.handle_z3(spec : String) : MCP::Protocol::CallToolResult
          result = execute_z3(spec)

          content = case result.status
                    when "sat"
                      "SATISFIABLE\nModel: #{result.model}"
                    when "unsat"
                      core = result.unsat_core
                      if core && !core.empty?
                        "UNSATISFIABLE\nUnsat core: #{core.join(", ")}"
                      else
                        "UNSATISFIABLE"
                      end
                    when "unknown"
                      "UNKNOWN: #{result.reason}"
                    when "error"
                      "ERROR: #{result.error}"
                    else
                      "UNEXPECTED RESULT: #{result}"
                    end

          MCP::Protocol::CallToolResult.new(
            content: [MCP::Protocol::TextContentBlock.new(content)]
          )
        end

        private def self.handle_prolog(spec : String, query : String?, explain : Bool, format : String) : MCP::Protocol::CallToolResult
          unless query
            return error_result("Query parameter required for prolog solver")
          end

          result = execute_prolog(normalize_prolog_spec(spec, format), query, explain)

          content = case result
                    when Solvers::SuccessResult
                      if result.answers.empty?
                        "SUCCESS: No answers found"
                      else
                        answers = result.answers.map_with_index do |answer, i|
                          lines = if answer.bindings.empty?
                                    "  true"
                                  else
                                    answer.bindings.map { |k, v| "  #{k} = #{v}" }.join("\n")
                                  end
                          "Answer #{i + 1}:\n#{lines}"
                        end.join("\n\n")
                        "SUCCESS\n#{answers}"
                      end
                    when Solvers::ErrorResult
                      "ERROR: #{result.error}"
                    else
                      "UNEXPECTED RESULT: #{result}"
                    end

          MCP::Protocol::CallToolResult.new(
            content: [MCP::Protocol::TextContentBlock.new(content)]
          )
        end

        private def self.error_result(message : String) : MCP::Protocol::CallToolResult
          MCP::Protocol::CallToolResult.new(
            content: [MCP::Protocol::TextContentBlock.new(message)]
          )
        end

        private def success_hash(result : JSON::Any) : Hash(String, JSON::Any)
          {
            "status" => JSON::Any.new("success"),
            "result" => result,
          }
        end

        private def error_hash(message : String) : Hash(String, JSON::Any)
          {
            "status" => JSON::Any.new("error"),
            "error"  => JSON::Any.new(message),
          }
        end

        private def run_z3(spec : String) : JSON::Any
          z3_result_json(execute_z3(spec))
        end

        private def run_prolog(spec : String, query : String, explain : Bool) : JSON::Any
          prolog_result_json(execute_prolog(spec, query, explain))
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

        private def execute_solver(input : Solvers::SolverInput) : Solvers::SolverResult
          solver = Solvers::Factory.build(input)
          begin
            solver.solve(input)
          ensure
            solver.dispose
          end
        end

        private def z3_result_json(result : Solvers::SolverResult) : JSON::Any
          json = case result
                 when Solvers::SatResult
                   {
                     "status" => JSON::Any.new("sat"),
                     "model"  => JSON.parse(result.model.to_json),
                   }
                 when Solvers::UnsatResult
                   {
                     "status"     => JSON::Any.new("unsat"),
                     "unsat_core" => result.unsat_core ? JSON.parse(result.unsat_core.to_json) : JSON::Any.new(nil),
                   }
                 when Solvers::UnknownResult
                   {
                     "status" => JSON::Any.new("unknown"),
                   }
                 when Solvers::ErrorResult
                   {
                     "status" => JSON::Any.new("error"),
                     "error"  => JSON::Any.new(result.error),
                   }
                 else
                   {
                     "status" => JSON::Any.new("unknown"),
                     "error"  => JSON::Any.new("Unexpected result type"),
                   }
                 end
          JSON.parse(json.to_json)
        end

        private def prolog_result_json(result : Solvers::SolverResult) : JSON::Any
          json = case result
                 when Solvers::SuccessResult
                   {
                     "status"  => JSON::Any.new(result.status),
                     "answers" => JSON.parse(result.answers.map { |answer|
                       {
                         "bindings"  => answer.bindings,
                         "formatted" => answer.formatted,
                       }
                     }.to_json),
                     "error" => JSON::Any.new(""),
                     "trace" => result.trace ? JSON.parse(result.trace.to_json) : JSON.parse("null"),
                   }
                 when Solvers::ErrorResult
                   {
                     "status"  => JSON::Any.new(result.status),
                     "answers" => JSON.parse("[]"),
                     "error"   => JSON::Any.new(result.error),
                     "trace"   => JSON.parse("null"),
                   }
                 else
                   {
                     "status"  => JSON::Any.new(result.status),
                     "answers" => JSON.parse("[]"),
                     "error"   => JSON::Any.new("Unexpected non-Prolog result"),
                     "trace"   => JSON.parse("null"),
                   }
                 end
          JSON.parse(json.to_json)
        end
      end
    end
  end
end
