# Chiasmus - Crystal port of chiasmus MCP server for formal verification
#
# This is a Crystal port of https://github.com/yogthos/chiasmus,
# an MCP server that gives LLMs access to formal verification via
# Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.
module Chiasmus
  VERSION = "0.1.0"

  # Main entry point for the MCP server
  # Uses environment configuration to determine provider
  def self.run
    server = MCPServer::Factory.from_env
    server.run
  end

  # Run with a specific provider
  def self.run_with_openai(
    api_key : String? = ENV["OPENAI_API_KEY"]?,
    base_url : String? = ENV["OPENAI_BASE_URL"]?,
    model : String = Crig::Providers::OpenAI::GPT_4O_MINI,
  )
    server = MCPServer::Factory.openai(api_key: api_key, base_url: base_url, model: model)
    server.run
  end

  # Run with DeepSeek provider
  def self.run_with_deepseek(
    api_key : String? = ENV["DEEPSEEK_API_KEY"]?,
    base_url : String? = ENV["DEEPSEEK_BASE_URL"]?,
    model : String = Crig::Providers::DeepSeek::DEEPSEEK_CHAT,
  )
    server = MCPServer::Factory.deepseek(api_key: api_key, base_url: base_url, model: model)
    server.run
  end
end

# Load all submodules
require "./chiasmus/**"
