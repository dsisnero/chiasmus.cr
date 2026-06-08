# Chiasmus - Crystal port of chiasmus MCP server for formal verification
#
# This is a Crystal port of https://github.com/yogthos/chiasmus,
# an MCP server that gives LLMs access to formal verification via
# Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.
module Chiasmus
  VERSION = "0.2.0"

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

  # Healthcheck — spawns server as child process and verifies MCP protocol via stdio
  def self.healthcheck
    binary = find_server_binary

    begin
      server_proc = Process.new(
        binary,
        output: Process::Redirect::Pipe,
        input: Process::Redirect::Pipe,
        error: Process::Redirect::Close,
      )

      sleep(3.seconds)

      # Send MCP initialize
      init = {
        jsonrpc: "2.0",
        id:      1,
        method:  "initialize",
        params:  {
          protocolVersion: MCP::Protocol::LATEST_PROTOCOL_VERSION,
          capabilities:    {} of String => String,
          clientInfo:      {name: "healthcheck", version: Chiasmus::VERSION},
        },
      }.to_json
      server_proc.input.puts(init)
      server_proc.input.flush

      response = server_proc.output.gets
      unless response
        puts "chiasmus healthcheck FAILED"
        puts "  error: no response to initialize"
        server_proc.terminate
        exit 1
      end

      parsed = JSON.parse(response)
      if parsed["error"]?
        puts "chiasmus healthcheck FAILED"
        puts "  error: #{parsed["error"]}"
        server_proc.terminate
        exit 1
      end

      # Send initialized notification
      initialized = {jsonrpc: "2.0", method: "notifications/initialized", params: {} of String => String}.to_json
      server_proc.input.puts(initialized)
      server_proc.input.flush

      # Send tools/list
      list_req = {jsonrpc: "2.0", id: 2, method: "tools/list", params: {} of String => String}.to_json
      server_proc.input.puts(list_req)
      server_proc.input.flush

      list_resp = server_proc.output.gets
      unless list_resp
        puts "chiasmus healthcheck FAILED"
        puts "  error: no response to tools/list"
        server_proc.terminate
        exit 1
      end

      list_result = JSON.parse(list_resp)
      tools = list_result["result"]?.try(&.["tools"]?.try(&.as_a))
      tool_count = tools.try(&.size) || 0

      if tool_count > 0
        puts "chiasmus healthcheck OK"
        puts "  version: #{Chiasmus::VERSION}"
        puts "  tools:   #{tool_count}"
        server_proc.terminate
        exit 0
      else
        puts "chiasmus healthcheck FAILED"
        puts "  error: no tools returned"
        server_proc.terminate
        exit 1
      end
    rescue ex
      puts "chiasmus healthcheck FAILED"
      puts "  error: #{ex.message || ex.class.name}"
      exit 1
    end
  end

  # Find the chiasmus server binary
  private def self.find_server_binary : String
    ENV["CHIASMUS_BIN"]? || begin
      bin = File.join(Dir.current, "bin", "chiasmus")
      return bin if File.file?(bin)

      bin = File.join(Dir.current, "bin", "chiasmus-static")
      return bin if File.file?(bin)

      # Try the same directory as the current executable
      if exe_path = Process.executable_path
        dir = File.dirname(exe_path)
        candidate = File.join(dir, "chiasmus")
        return candidate if File.file?(candidate)
      end

      "chiasmus"
    end
  end
end

# Load all submodules
require "./chiasmus/**"

# CLI entry point — compiled only for the chiasmus binary target
{% if flag?(:chiasmus_cli) %}
  require "clip"

  @[Clip::Doc("Chiasmus MCP server — formal verification with Z3, Prolog, and tree-sitter analysis.")]
  struct ChiasmusCLI
    include Clip::Mapper

    @[Clip::Option("--version")]
    getter? version : Bool = false

    @[Clip::Option("--healthcheck")]
    getter? healthcheck : Bool = false
  end

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
    else
      Chiasmus.run
    end
  end
{% end %}
