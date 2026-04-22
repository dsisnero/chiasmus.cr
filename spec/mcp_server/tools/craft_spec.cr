require "../../spec_helper"
require "file_utils"

def with_craft_server(&)
  dir = File.join(Dir.tempdir, "chiasmus-craft-tool-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)

  with_env({
    "CHIASMUS_HOME" => dir,
  }) do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    begin
      yield server, dir
    ensure
      server.skill_library.close
      Chiasmus::MCPServer.current_server = nil
      FileUtils.rm_rf(dir)
    end
  end
end

describe Chiasmus::MCPServer::Tools::CraftTool do
  it "creates a template via MCP" do
    with_craft_server do |server, _dir|
      tool = Chiasmus::MCPServer::Tools::CraftTool.new

      result = tool.invoke({
        "name"      => JSON::Any.new("mcp-test-template"),
        "domain"    => JSON::Any.new("validation"),
        "solver"    => JSON::Any.new("z3"),
        "signature" => JSON::Any.new("Test template created via MCP"),
        "skeleton"  => JSON::Any.new("(declare-const x Int)\n(assert {{SLOT:condition}})"),
        "slots"     => JSON.parse(%([
          {"name":"condition","description":"Test condition","format":"(> x 0)"}
        ])),
        "normalizations" => JSON.parse(%([
          {"source":"test input","transform":"Map to SMT expression"}
        ])),
      })

      result["created"].as_bool.should be_true
      result["template"].as_s.should eq("mcp-test-template")
      server.skill_library.get("mcp-test-template").should_not be_nil
    end
  end

  it "returns validation errors for bad input" do
    with_craft_server do |_server, _dir|
      tool = Chiasmus::MCPServer::Tools::CraftTool.new

      result = tool.invoke({
        "name"           => JSON::Any.new(""),
        "domain"         => JSON::Any.new("test"),
        "solver"         => JSON::Any.new("invalid"),
        "signature"      => JSON::Any.new(""),
        "skeleton"       => JSON::Any.new(""),
        "slots"          => JSON.parse(%([])),
        "normalizations" => JSON.parse(%([])),
      })

      result["created"].as_bool.should be_false
      result["errors"].as_a.should_not be_empty
    end
  end
end
