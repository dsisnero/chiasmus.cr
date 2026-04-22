# Main MCP server implementation for chiasmus
require "mcp"
require "crig"

module Chiasmus
  module MCPServer
    RUNTIME_LOCK = Mutex.new

    abstract class BaseServer
      abstract def skill_library : Skills::Library
      abstract def skill_learner : Skills::Learner?
      abstract def formalize(problem : String) : Formalize::FormalizeResult?
      abstract def solve(problem : String, max_rounds : Int32 = 5) : Formalize::SolveResult?
    end

    class_property current_server : BaseServer? = nil
    class_property current_skill_learner : Skills::Learner? = nil

    # Main server class that orchestrates all chiasmus functionality
    # Generic over model type M to support different LLM providers
    class Server(M) < BaseServer
      @formalization_engine : Formalize::Engine(M)?
      @skill_learner : Skills::Learner?

      # Create a server instance with a specific agent
      def self.with_agent(agent : Crig::Agent(M)) : Server(M)
        MCPServer::RUNTIME_LOCK.synchronize do
          server = new
          server.with_agent(agent)
          MCPServer.current_server = server
          server
        end
      end

      # Keep the builder-first Crig flow available for local callers and specs.
      def self.with_agent_builder(builder : Crig::AgentBuilder(M)) : Server(M)
        with_agent(builder.build)
      end

      getter skill_library : Skills::Library
      getter solver_session : Solvers::Session
      getter skill_learner : Skills::Learner?

      def initialize
        @config = Utils::Config.load
        @skill_library = Skills::Library.create(self.class.chiasmus_home)
        @solver_session = Solvers::Session.instance
        @skill_learner = nil
        MCPServer.current_skill_learner = nil
        @formalization_engine = nil

        # Tools are automatically registered by MCP::AbstractTool inheritance
        # No need to manually instantiate them
      end

      # Set the agent for formalization engine
      def with_agent(agent : Crig::Agent(M)) : self
        @formalization_engine = Formalize::Engine.new(@skill_library, agent)
        @skill_learner = Skills::Learner.new(@skill_library, build_skill_extractor(agent))
        MCPServer.current_skill_learner = @skill_learner
        self
      end

      def with_agent_builder(builder : Crig::AgentBuilder(M)) : self
        with_agent(builder.build)
      end

      def formalization_engine : Formalize::Engine(M)?
        @formalization_engine
      end

      def formalize(problem : String) : Formalize::FormalizeResult?
        @formalization_engine.try(&.formalize(problem))
      end

      def solve(problem : String, max_rounds : Int32 = 5) : Formalize::SolveResult?
        @formalization_engine.try(&.solve(problem, max_rounds))
      end

      # Start the MCP server
      def run
        puts "Starting chiasmus MCP server v#{Chiasmus::VERSION}"
        puts "Formal verification server with Z3, Prolog, and tree-sitter analysis"

        # Get registered tools from MCP
        tools = MCP.registered_tools
        puts "Available tools: #{tools.keys.join(", ")}"

        # Start stdio MCP server
        MCP::StdioHandler.start_server
      end

      # Get chiasmus home directory (delegates to Config)
      def self.chiasmus_home : String
        Utils::Config.chiasmus_home
      end

      private def build_skill_extractor(agent : Crig::Agent(M)) : Skills::Learner::Extractor
        ->(solver : Solvers::SolverType, verified_spec : String, problem_description : String) do
          agent.prompt(
            <<-CONTENT
            #{Skills::Learner::EXTRACT_SYSTEM}

            SOLVER: #{solver.to_s.downcase}
            VERIFIED SPECIFICATION:
            #{verified_spec}

            PROBLEM DESCRIPTION: #{problem_description}

            Extract a reusable template from this verified solution.
            CONTENT
          ).send
        end
      end
    end
  end
end
