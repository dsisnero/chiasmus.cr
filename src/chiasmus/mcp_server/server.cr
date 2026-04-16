# Main MCP server implementation for chiasmus
require "mcp"

module Chiasmus
  module MCPServer
    # Main server class that orchestrates all chiasmus functionality
    class Server
      def initialize
        @config = Utils::Config.load
        @skill_library = Skills::Library.create(self.class.chiasmus_home)
        @formalization_engine = Formalize::Engine.new(@skill_library, LLM::MockAdapter.new)
        @solver_session = Solvers::Session.new
        @skill_learner = Skills::Learner.new

        # Tools are automatically registered by MCP::AbstractTool inheritance
        # No need to manually instantiate them
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
