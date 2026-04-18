# Main MCP server implementation for chiasmus
require "mcp"
require "crig"

module Chiasmus
  module MCPServer
    # Main server class that orchestrates all chiasmus functionality
    # Generic over model type M to support different LLM providers
    class Server(M)
      @formalization_engine : Formalize::Engine(M)?
      @@instance : Server(M)?
      @@instance_lock = Mutex.new

      # Create a server instance with a specific agent
      def self.with_agent(agent : Crig::Agent(M)) : Server(M)
        @@instance_lock.synchronize do
          server = new
          server.with_agent(agent)
          @@instance = server
          server
        end
      end

      # Get or create instance (requires agent to be set first)
      def self.instance : Server(M)
        @@instance_lock.synchronize do
          @@instance || raise "Server instance not initialized. Call Server.with_agent first."
        end
      end

      getter skill_library : Skills::Library
      getter solver_session : Solvers::Session
      getter skill_learner : Skills::Learner

      def initialize
        @config = Utils::Config.load
        @skill_library = Skills::Library.create(self.class.chiasmus_home)
        @solver_session = Solvers::Session.instance
        @skill_learner = Skills::Learner.new
        @formalization_engine = nil

        # Tools are automatically registered by MCP::AbstractTool inheritance
        # No need to manually instantiate them
      end

      # Set the agent for formalization engine
      def with_agent(agent : Crig::Agent(M)) : self
        @formalization_engine = Formalize::Engine.new(@skill_library, agent)
        self
      end

      def formalization_engine : Formalize::Engine(M)?
        @formalization_engine
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
    end
  end
end
