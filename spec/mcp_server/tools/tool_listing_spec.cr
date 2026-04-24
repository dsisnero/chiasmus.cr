require "../../spec_helper"

describe "MCP tool listing" do
  it "lists chiasmus_verify as an available tool" do
    Chiasmus::MCPServer::Tools::VerifyTool.tool_name.should eq("chiasmus_verify")
  end

  it "lists chiasmus_formalize as an available tool" do
    Chiasmus::MCPServer::Tools::FormalizeTool.tool_name.should eq("chiasmus_formalize")
  end

  it "lists chiasmus_skills as an available tool" do
    Chiasmus::MCPServer::Tools::SkillsTool.tool_name.should eq("chiasmus_skills")
  end

  it "lists chiasmus_solve as an available tool" do
    Chiasmus::MCPServer::Tools::SolveTool.tool_name.should eq("chiasmus_solve")
  end

  it "lists chiasmus_lint as an available tool" do
    Chiasmus::MCPServer::Tools::LintTool.tool_name.should eq("chiasmus_lint")
  end

  it "lists chiasmus_craft as an available tool" do
    Chiasmus::MCPServer::Tools::CraftTool.tool_name.should eq("chiasmus_craft")
  end
end

describe "created template in skills search" do
  it "appears in chiasmus_skills search after being created via chiasmus_craft" do
    dir = File.join(Dir.tempdir, "chiasmus-craft-search-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    with_env({
      "CHIASMUS_HOME" => dir,
    }) do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      Chiasmus::MCPServer.current_server = server

      begin
        craft = Chiasmus::MCPServer::Tools::CraftTool.new
        craft.invoke({
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

        skills = Chiasmus::MCPServer::Tools::SkillsTool.new
        result = skills.invoke({
          "query" => JSON::Any.new("Test template created via MCP"),
        })

        result["status"].as_s.should eq("success")
        names = result["templates"].as_a.map { |t| t.as_h["name"].as_s }
        names.should contain("mcp-test-template")
      ensure
        server.skill_library.close
        Chiasmus::MCPServer.current_server = nil
        FileUtils.rm_rf(dir)
      end
    end
  end
end
