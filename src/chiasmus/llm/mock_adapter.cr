require "./types"

module Chiasmus
  module LLM
    # Mock LLM adapter for testing
    class MockAdapter < Adapter
      @responses : Hash(String, String)

      def initialize
        @responses = Hash(String, String).new
      end

      def add_response(key : String, response : String) : Nil
        @responses[key] = response
      end

      def complete(system : String, messages : Array(LLMMessage)) : String
        # For testing, return a canned response based on the last user message
        last_message = messages.last?
        return "" unless last_message && last_message.role == "user"

        # Try to find a matching response
        @responses.each do |key, response|
          if last_message.content.includes?(key)
            return response
          end
        end

        # Default response
        "Mock LLM response for: #{last_message.content[0..50]}..."
      end
    end
  end
end
