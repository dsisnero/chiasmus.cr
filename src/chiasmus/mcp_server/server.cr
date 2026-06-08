# Main MCP server implementation for chiasmus
require "json"
require "mcp"
require "crig"
require "./tools/verify"
require "./tools/skills"
require "./tools/formalize"
require "./tools/solve"
require "./tools/learn"
require "./tools/lint"
require "./tools/graph"
require "./tools/map"
require "./tools/search"
require "./tools/craft"
require "./tools/review"
require "./tools/crig"

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
      def self.with_agent(agent : Crig::Agent(M)) forall M
        MCPServer::RUNTIME_LOCK.synchronize do
          server = Server(M).new
          server.with_agent(agent)
          MCPServer.current_server = server
          server
        end
      end

      # Keep the builder-first Crig flow available for local callers and specs.
      def self.with_agent_builder(builder : Crig::AgentBuilder(M)) forall M
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

      # Start the MCP server on stdio
      def run
        # All diagnostics MUST go to stderr — stdout is reserved for JSON-RPC
        Log.setup(:warn, Log::IOBackend.new(STDERR))

        STDERR.puts "Starting chiasmus MCP server v#{Chiasmus::VERSION}"
        STDERR.puts "Formal verification server with Z3, Prolog, and tree-sitter analysis"

        mcp = build_mcp_transport
        wg = WaitGroup.new(1)

        mcp.on_close do
          STDERR.puts "[Chiasmus] MCP server shutting down"
          @skill_library.close rescue nil
          wg.done
        end

        Signal::INT.trap do
          mcp.close rescue nil
          wg.done
        end

        Signal::TERM.trap do
          mcp.close rescue nil
          wg.done
        end

        wg.spawn { mcp.connect(MCP::Server::StdioServerTransport.new(STDIN, STDOUT)) }
        wg.wait
      end

      # Perform an in-memory healthcheck: MCP initialize + tools/list
      def healthcheck : NamedTuple(success: Bool, tools: Int32?, version: String?, error: String?)
        mcp = build_mcp_transport

        server_t = MCP::Shared::InMemoryTransport.new
        client_t = MCP::Shared::InMemoryTransport.new
        server_t.other_transport = client_t
        client_t.other_transport = server_t

        mcp.connect(server_t)

        client = MCP::Client::Client.new(
          MCP::Protocol::Implementation.new(name: "healthcheck", version: Chiasmus::VERSION)
        )

        begin
          client.connect(client_t)
          result = client.list_tools

          {
            success: true,
            tools:   result.try(&.tools.size) || 0,
            version: Chiasmus::VERSION,
            error:   nil,
          }
        rescue ex
          {
            success: false,
            tools:   nil,
            version: nil,
            error:   ex.message,
          }
        ensure
          mcp.close rescue nil
          client.close rescue nil
        end
      end

      # Build and wire the MCP transport server with all tools registered
      def build_mcp_transport : MCP::Server::Server
        capabilities = MCP::Protocol::ServerCapabilities.new(
          tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
        )
        options = MCP::Server::ServerOptions.new(capabilities: capabilities)

        mcp_server = MCP::Server::Server.new(
          MCP::Protocol::Implementation.new(name: "chiasmus", version: Chiasmus::VERSION),
          options
        )

        register_tools(mcp_server)
        mcp_server
      end

      private def register_tools(mcp_server : MCP::Server::Server)
        tool_defs = [
          {Tools::VerifyTool, Tools::VerifyTool.tool_name, Tools::VerifyTool.tool_description, Tools::VerifyTool.input_schema},
          {Tools::SkillsTool, Tools::SkillsTool.tool_name, Tools::SkillsTool.tool_description, Tools::SkillsTool.input_schema},
          {Tools::FormalizeTool, Tools::FormalizeTool.tool_name, Tools::FormalizeTool.tool_description, Tools::FormalizeTool.input_schema},
          {Tools::SolveTool, Tools::SolveTool.tool_name, Tools::SolveTool.tool_description, Tools::SolveTool.input_schema},
          {Tools::LearnTool, Tools::LearnTool.tool_name, Tools::LearnTool.tool_description, Tools::LearnTool.input_schema},
          {Tools::LintTool, Tools::LintTool.tool_name, Tools::LintTool.tool_description, Tools::LintTool.input_schema},
          {Tools::GraphTool, Tools::GraphTool.tool_name, Tools::GraphTool.tool_description, Tools::GraphTool.input_schema},
          {Tools::MapTool, Tools::MapTool.tool_name, Tools::MapTool.tool_description, Tools::MapTool.input_schema},
          {Tools::SearchTool, Tools::SearchTool.tool_name, Tools::SearchTool.tool_description, Tools::SearchTool.input_schema},
          {Tools::CraftTool, Tools::CraftTool.tool_name, Tools::CraftTool.tool_description, Tools::CraftTool.input_schema},
          {Tools::ReviewTool, Tools::ReviewTool.tool_name, Tools::ReviewTool.tool_description, Tools::ReviewTool.input_schema},
          {Tools::CrigTool, Tools::CrigTool.tool_name, Tools::CrigTool.tool_description, Tools::CrigTool.input_schema},
        ]

        tool_defs.each do |(tool_class, name, description, input_schema)|
          tool_instance = tool_class.new
          mcp_server.add_tool(name, description, input_schema) do |params|
            arguments = params.arguments || {} of String => JSON::Any
            result = tool_instance.invoke(arguments)
            result_json = result.to_json
            content = [MCP::Protocol::TextContentBlock.new(result_json)] of MCP::Protocol::ContentBlock
            structured = begin
              JSON.parse(result_json).as_h
            rescue
              nil
            end
            MCP::Protocol::CallToolResult.new(content: content, structured_content: structured)
          end
        end
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
