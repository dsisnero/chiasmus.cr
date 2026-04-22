require "../../spec_helper"
require "crig"

class LearnSpecCompletionModel
  include Crig::Completion::CompletionModel

  def initialize(@response : String)
  end

  def completion(request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
    Crig::Completion::CompletionResponse(String).new(
      choice: Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.new(
          kind: Crig::Completion::AssistantContent::Kind::Text,
          text: Crig::Completion::Text.new(@response)
        )
      ),
      usage: Crig::Completion::Usage.new(
        input_tokens: 10,
        output_tokens: 20,
        total_tokens: 30
      ),
      raw_response: @response
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "streaming not implemented for learn spec"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.from_prompt(prompt)
  end
end

class LearnSpecClient
  include Crig::Client::CompletionClient(LearnSpecCompletionModel)

  def initialize(@response : String)
  end

  def completion_model(model : String) : LearnSpecCompletionModel
    LearnSpecCompletionModel.new(@response)
  end
end

def build_learn_spec_agent_builder(response : String)
  LearnSpecClient.new(response).agent("mock")
end

describe Chiasmus::MCPServer::Tools::LearnTool do
  it "returns an error when no learner is available" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    tool = Chiasmus::MCPServer::Tools::LearnTool.new

    result = tool.invoke({
      "solver"  => JSON::Any.new("z3"),
      "spec"    => JSON::Any.new("(declare-const x Int)"),
      "problem" => JSON::Any.new("test"),
    })

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("LLM")
    server.skill_learner.should be_nil
  end

  it "extracts a template when the server has an agent-backed learner" do
    response = {
      "name"      => "port-range-overlap",
      "domain"    => "configuration",
      "signature" => "Check if two port ranges overlap",
      "slots"     => [
        {"name" => "range_a_constraints", "description" => "First port range bounds", "format" => "(assert (and (>= port 80) (<= port 443)))"},
      ],
      "normalizations" => [
        {"source" => "firewall rules", "transform" => "Extract port ranges from rule definitions"},
      ],
      "skeleton" => "{{SLOT:range_a_constraints}}",
    }.to_json
    builder = build_learn_spec_agent_builder(response)
    server = Chiasmus::MCPServer::Server(LearnSpecCompletionModel).with_agent_builder(builder)
    tool = Chiasmus::MCPServer::Tools::LearnTool.new

    result = tool.invoke({
      "solver"  => JSON::Any.new("z3"),
      "spec"    => JSON::Any.new("(declare-const port Int)"),
      "problem" => JSON::Any.new("Check if two port ranges overlap"),
    })

    result["status"].as_s.should eq("success")
    result["template"].as_s.should eq("port-range-overlap")
    server.skill_library.get("port-range-overlap").should_not be_nil
  end
end
