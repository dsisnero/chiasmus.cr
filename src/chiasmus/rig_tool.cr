# Chiasmus rig tool - Exposes formal verification as a Crig tool
require "crig"
require "./llm/types"
require "./formalize/engine"
require "./solvers/session"
require "./skills/library"

module Chiasmus
  # Rig tool that wraps chiasmus functionality for use in Crig agents
  class RigTool(M)
    include Crig::Tool(Hash(String, JSON::Any), String)

    getter name : String = "chiasmus"

    def definition(prompt : String) : Crig::Completion::ToolDefinition
      # Create JSON schema for parameters
      schema = {
        "type"       => "object",
        "properties" => {
          "problem" => {
            "type"        => "string",
            "description" => "Natural language problem to solve",
          },
          "solver" => {
            "type"        => "string",
            "description" => "Solver to use: 'z3', 'prolog', or 'auto'",
            "enum"        => ["z3", "prolog", "auto"],
          },
          "debug" => {
            "type"        => "boolean",
            "description" => "Enable debug output",
            "default"     => false,
          },
        },
        "required" => ["problem"],
      }

      Crig::Completion::ToolDefinition.new(
        name: name,
        description: "Formal verification tool. Use Z3 or Prolog to solve logical problems.",
        parameters: JSON.parse(schema.to_json)
      )
    end

    def call_typed(args : Hash(String, JSON::Any)) : String
      call(args)
    end

    @engine : Formalize::Engine(M)?
    @session : Solvers::Session?
    @library : Skills::Library?

    def initialize(agent : Crig::Agent(M)? = nil)
      # Initialize with provided agent or default
      if agent
        @library = Skills::Library.create(chiasmus_home)
        library = @library || raise "Skill library initialization failed"
        @engine = Formalize::Engine.new(library, agent)
      else
        # Cannot use LLM.agent directly due to type system limitations
        # Users should provide an agent or use ChiasmusAgent.create
        @library = nil
        @engine = nil
      end

      @session = Solvers::Session.instance
    end

    def call(arguments : Hash(String, JSON::Any)) : String
      problem = arguments["problem"]?.try(&.as_s)
      solver_type = arguments["solver"]?.try(&.as_s) || "auto"
      debug = arguments["debug"]?.try(&.as_bool?) || false

      return error_response("Problem is required") unless problem
      return error_response("LLM not available. Set API key.") unless @engine

      # Formalize the problem
      engine = @engine || raise "Formalization engine not available"
      formalize_result = engine.formalize(problem)
      template = formalize_result.template

      # Determine solver
      solver = case solver_type
               when "z3"     then Solvers::Z3Solver.new
               when "prolog" then Solvers::PrologSolver.new
               when "auto"
                 case template.solver
                 when Solvers::SolverType::Z3     then Solvers::Z3Solver.new
                 when Solvers::SolverType::Prolog then Solvers::PrologSolver.new
                 else                                  Solvers::Z3Solver.new
                 end
               else Solvers::Z3Solver.new
               end

      # Use engine's solve method which handles the whole process
      solve_result = engine.solve(problem)

      if debug
        puts "=== DEBUG ==="
        puts "Template: #{template.name}"
        puts "Solver: #{solver.class}"
        puts "Rounds: #{solve_result.rounds}"
        puts "Converged: #{solve_result.converged}"
        puts "============="
      end

      # Get the final result
      result = solve_result.result

      # Format response
      format_response(problem, template, solver, result, debug)
    end

    private def chiasmus_home : String
      Utils::Config.chiasmus_home
    end

    private def error_response(message : String) : String
      JSON.build do |json|
        json.object do
          json.field "status", "error"
          json.field "error", message
        end
      end
    end

    private def format_response(
      problem : String,
      template : Skills::SkillTemplate,
      solver : Solvers::Solver,
      result : Solvers::SolverResult,
      debug : Bool,
    ) : String
      JSON.build do |json|
        json.object do
          json.field "status", "success"
          json.field "problem", problem
          json.field "template", template.name
          json.field "solver", solver.class.name.split("::").last

          case result
          when Solvers::SatResult, Solvers::UnsatResult, Solvers::UnknownResult, Solvers::ErrorResult
            # Z3 results
            json.field "result_type", "z3"

            case result
            when Solvers::SatResult
              sat_result = result.as(Solvers::SatResult)
              json.field "satisfiable", true
              json.field "model", sat_result.model
            when Solvers::UnsatResult
              unsat_result = result.as(Solvers::UnsatResult)
              json.field "satisfiable", false
              json.field "unsat_core", unsat_result.unsat_core if unsat_result.unsat_core
            when Solvers::UnknownResult
              json.field "satisfiable", false
              json.field "status", "unknown"
            when Solvers::ErrorResult
              error_result = result.as(Solvers::ErrorResult)
              json.field "satisfiable", false
              json.field "error", error_result.error
            end
          when Solvers::SuccessResult
            # Prolog result
            prolog_result = result.as(Solvers::SuccessResult)
            json.field "result_type", "prolog"
            json.field "success", true
            json.field "answers", prolog_result.answers.map(&.bindings)
          end

          if debug
            json.field "debug", true
            json.field "solver_class", solver.class.name
          end
        end
      end
    end
  end

  # Agent wrapper that integrates chiasmus as a reasoning tool
  class ChiasmusAgent(M)
    @agent : Crig::Agent(M)
    @tool : RigTool(M)

    def initialize(agent : Crig::Agent(M))
      @agent = agent
      @tool = RigTool(M).new(agent)
    end

    # Create a chiasmus-enhanced agent
    # Note: In Crig, tools are added through AgentBuilder, not Agent
    # This method shows how to create an agent with chiasmus tool
    def self.create_example(agent_builder : Crig::AgentBuilder(M)) : Crig::AgentBuilder(M)
      # Create a tool definition
      tool_def = RigTool(M).new(nil).definition("")
      agent_builder.static_tools([tool_def])
    end

    # Interactive REPL
    def repl
      print_repl_banner

      loop do
        print "> "
        input = gets.try(&.strip)

        break if input.nil? || input.downcase == "quit"
        next if input.empty?

        begin
          # Use the tool directly
          result = @tool.call({"problem" => JSON::Any.new(input)})
          parsed = JSON.parse(result)
          display_repl_result(parsed)
        rescue ex
          puts "✗ Exception: #{ex.message}"
          puts ex.backtrace.first(3).join("\n") if ENV["DEBUG"]?
        end

        puts
      end

      puts "Goodbye!"
    end

    private def print_repl_banner : Nil
      puts "=== Chiasmus Agent REPL ==="
      puts "Type a problem to solve formally (or 'quit' to exit)"
      puts "Examples:"
      puts "  - 'Find x such that x + 5 = 10'"
      puts "  - 'All men are mortal. Socrates is a man. Is Socrates mortal?'"
      puts "  - 'Alice is older than Bob. Bob is older than Carol. Is Alice older than Carol?'"
      puts "======================================"
    end

    private def display_repl_result(parsed : JSON::Any) : Nil
      unless parsed["status"] == "success"
        puts "✗ Error: #{parsed["error"]}"
        return
      end

      puts "✓ Solved using #{parsed["template"]} (#{parsed["solver"]})"

      case parsed["result_type"].as_s
      when "z3"
        display_z3_repl_result(parsed)
      when "prolog"
        display_prolog_repl_result(parsed)
      end
    end

    private def display_z3_repl_result(parsed : JSON::Any) : Nil
      if parsed["satisfiable"].as_bool
        puts "  Model: #{parsed["model"]}"
      else
        puts "  Unsatisfiable"
        if unsat = parsed["unsat_core"]?
          puts "  Unsat core: #{unsat}"
        end
      end
    end

    private def display_prolog_repl_result(parsed : JSON::Any) : Nil
      unless parsed["success"].as_bool
        puts "  No solutions found"
        return
      end

      answers = parsed["answers"].as_a
      puts "  Found #{answers.size} answer(s):"
      answers.each_with_index do |answer, index|
        puts "  #{index + 1}. #{answer}"
      end
    end

    # Solve a single problem
    def solve(problem : String, solver : String = "auto", debug : Bool = false) : String
      @tool.call({
        "problem" => JSON::Any.new(problem),
        "solver"  => JSON::Any.new(solver),
        "debug"   => JSON::Any.new(debug),
      })
    end
  end
end
