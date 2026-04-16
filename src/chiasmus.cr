# Chiasmus - Crystal port of chiasmus MCP server for formal verification
#
# This is a Crystal port of https://github.com/yogthos/chiasmus,
# an MCP server that gives LLMs access to formal verification via
# Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.
module Chiasmus
  VERSION = "0.1.0"

  # Main entry point for the MCP server
  def self.run
    MCPServer::Server.new.run
  end
end

# Load all submodules
require "./chiasmus/**"
