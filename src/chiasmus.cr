# Chiasmus - Crystal port of chiasmus MCP server for formal verification
#
# This is a Crystal port of https://github.com/yogthos/chiasmus,
# an MCP server that gives LLMs access to formal verification via
# Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.
module Chiasmus
  # Single source of truth: read the version from shard.yml at compile time
  # so `--version`, the startup banner, and the shard stay in sync.
  VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find { |line| line.starts_with?("version:") }.split(":")[1].strip }}

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

  # Healthcheck — verifies MCP server via in-memory transport without spawning a child process
  def self.healthcheck
    server = MCPServer::Factory.from_env
    begin
      result = server.healthcheck
      if result[:success]
        puts "chiasmus healthcheck OK"
        puts "  version: #{result[:version]}"
        puts "  tools:   #{result[:tools]}"
      else
        puts "chiasmus healthcheck FAILED"
        puts "  error: #{result[:error]}"
        exit 1
      end
    rescue ex
      puts "chiasmus healthcheck FAILED"
      puts "  error: #{ex.message || ex.class.name}"
      exit 1
    ensure
      server.skill_library.close rescue nil
    end
  end

  # Run server on streamable HTTP transport for debugging with mcp-debug
  def self.run_streamable(port : Int32 = 8899)
    server = MCPServer::Factory.from_env
    server.run_streamable(port)
  end
end

# Load all submodules
require "./chiasmus/**"

# CLI entry point
require "clip"

# CLI entry point — runs when this file is the main executable.
# The ChiasmusCLI struct must be available at compile time for Clip::Mapper,
# so we always define it. The case block runs at runtime via at_exit
# only when PROGRAM_NAME indicates we're a chiasmus binary, avoiding
# interference with test suites (where require loads the module without
# executing the CLI).
@[Clip::Doc("Chiasmus MCP server — formal verification with Z3, Prolog, and tree-sitter analysis.")]
struct ChiasmusCLI
  include Clip::Mapper

  @[Clip::Option("--version")]
  getter? version : Bool = false

  @[Clip::Option("--healthcheck")]
  getter? healthcheck : Bool = false

  @[Clip::Option("--streamable")]
  getter? streamable : Bool = false

  @[Clip::Option("--port")]
  getter port : Int32 = 8899
end

{% if flag?(:chiasmus_cli) %}
  at_exit do
    begin
      cli = ChiasmusCLI.parse(ARGV)
    rescue ex : Clip::ParsingError
      puts ex
      exit 1
    end

    case cli
    when Clip::Mapper::Help
      puts cli.help
    when ChiasmusCLI
      if cli.version?
        puts "chiasmus v#{Chiasmus::VERSION}"
      elsif cli.healthcheck?
        Chiasmus.healthcheck
      elsif cli.streamable?
        Chiasmus.run_streamable(cli.port)
      else
        Chiasmus.run
      end
    end
  end
{% end %}
