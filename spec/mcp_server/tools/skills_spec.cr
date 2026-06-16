require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::SkillsTool do
  it "searches for templates by query" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "query" => JSON::Any.new("check if access control policies conflict"),
    })

    result.status.should eq("success")
    result.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.first.name.should eq("policy-contradiction")
  end

  it "returns related suggestions for an exact template lookup" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "name" => JSON::Any.new("policy-contradiction"),
    })

    result.status.should eq("success")
    skills = result.as(Chiasmus::MCPServer::Types::SkillsResponse)
    skills.templates.first.name.should eq("policy-contradiction")
    suggestions = skills.suggestions || raise "Expected suggestions"
    suggestions.map { |sug| sug["name"]?.try(&.as_s?) }.should contain("policy-reachability")
    suggestions.map { |sug| sug["name"]?.try(&.as_s?) }.should contain("permission-derivation")
  end

  it "lists all starter templates when no query or name is given" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({} of String => JSON::Any)

    result.status.should eq("success")
    result.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.size.should be >= Chiasmus::Skills::STARTER_TEMPLATES.size
  end

  it "filters by solver type" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("prolog"),
    })

    result.status.should eq("success")
    result.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.each do |item|
      item.solver.should eq("prolog")
    end
  end

  it "returns an error for unknown template names" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "name" => JSON::Any.new("nonexistent-template"),
    })

    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("not found")
  end

  it "filters templates by domain" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "domain" => JSON::Any.new("authorization"),
    })

    result.status.should eq("success")
    templates = result.as(Chiasmus::MCPServer::Types::SkillsResponse).templates
    templates.should_not be_empty
    templates.each do |tmpl|
      tmpl.domain.should eq("authorization")
    end
  end

  it "returns results sorted with highest relevance first" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SkillsTool.new

    result = tool.invoke({
      "query" => JSON::Any.new("policy conflict"),
    })

    result.status.should eq("success")
    templates = result.as(Chiasmus::MCPServer::Types::SkillsResponse).templates
    templates.should_not be_empty
    templates.size.should be >= 2
    templates.first.domain.should eq("authorization")
  end
end
