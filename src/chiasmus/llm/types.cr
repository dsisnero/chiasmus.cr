module Chiasmus
  module LLM
    # A message in the LLM conversation
    record LLMMessage,
      role : String, # "user" or "assistant"
      content : String

    # Interface for LLM backends
    abstract class Adapter
      # Generate a completion from a system prompt and messages
      abstract def complete(system : String, messages : Array(LLMMessage)) : String
    end
  end
end
