require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::SkillsTool do
  it "searches for templates by query" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "query" => JSON::Any.new("check if access control policies conflict"),
    })

    result["status"].as_s.should eq("success")
    result["templates"].as_a.first.as_h["name"].as_s.should eq("policy-contradiction")
  end

  it "returns related suggestions for an exact template lookup" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "name" => JSON::Any.new("policy-contradiction"),
    })

    result["status"].as_s.should eq("success")
    result["templates"].as_a.first.as_h["name"].as_s.should eq("policy-contradiction")
    suggestions = result["suggestions"].as_a
    suggestions.map(&.as_h["name"].as_s).should contain("policy-reachability")
    suggestions.map(&.as_h["name"].as_s).should contain("permission-derivation")
  end

  it "lists all starter templates when no query or name is given" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({} of String => JSON::Any)

    result["status"].as_s.should eq("success")
    result["templates"].as_a.size.should eq(Chiasmus::Skills::STARTER_TEMPLATES.size)
  end

  it "filters by solver type" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("prolog"),
    })

    result["status"].as_s.should eq("success")
    result["templates"].as_a.each do |item|
      item.as_h["solver"].as_s.should eq("prolog")
    end
  end

  it "returns an error for unknown template names" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "name" => JSON::Any.new("nonexistent-template"),
    })

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("not found")
  end
end
