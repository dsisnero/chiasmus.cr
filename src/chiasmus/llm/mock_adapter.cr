require "./types"
require "crig"

module Chiasmus
  module LLM
    # Simple mock completion model for testing
    class MockCompletionModel
      include Crig::Completion::CompletionModel

      def completion(request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
        # Return a simple mock response
        Crig::Completion::CompletionResponse(String).new(
          choice: Crig::OneOrMany(Crig::Completion::AssistantContent).one(
            Crig::Completion::AssistantContent.new(
              kind: Crig::Completion::AssistantContent::Kind::Text,
              text: Crig::Completion::Text.new("Mock response")
            )
          ),
          usage: Crig::Completion::Usage.new(
            input_tokens: 10,
            output_tokens: 20,
            total_tokens: 30
          ),
          raw_response: "Mock response"
        )
      end

      def stream(request : Crig::Completion::Request::CompletionRequest)
        raise "Mock streaming not implemented"
      end

      def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
        Crig::Completion::Request::CompletionRequestBuilder.from_prompt(prompt)
      end
    end

    # Mock client for testing
    class MockClient
      def agent(model : String) : Crig::AgentBuilder(MockCompletionModel)
        Crig::AgentBuilder(MockCompletionModel).new(MockCompletionModel.new, model)
      end
    end

    # Helper methods for testing
    module MockAdapter
      def self.create_agent : Crig::Agent(MockCompletionModel)
        client = MockClient.new
        client.agent("mock").build
      end
    end
  end
end
