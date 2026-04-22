class FormalizeSpecCompletionModel
  include Crig::Completion::CompletionModel

  def initialize(@responses : Array(String), @prompts : Array(String))
    @index = 0
  end

  def completion(request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
    @prompts << request.chat_history.to_a.map { |message| extract_text(message) }.join("\n\n")
    response = @responses[@index]? || @responses.last? || ""
    @index += 1 if @index < @responses.size

    Crig::Completion::CompletionResponse(String).new(
      choice: Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.new(
          kind: Crig::Completion::AssistantContent::Kind::Text,
          text: Crig::Completion::Text.new(response)
        )
      ),
      usage: Crig::Completion::Usage.new(
        input_tokens: 10,
        output_tokens: 20,
        total_tokens: 30
      ),
      raw_response: response
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "streaming not implemented for formalize spec"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.from_prompt(prompt)
  end

  private def extract_text(message : Crig::Completion::Message) : String
    message.content.to_a.compact_map do |content|
      case content
      when Crig::Completion::UserContent
        content.text.try(&.text)
      when Crig::Completion::AssistantContent
        content.text.try(&.text)
      else
        nil
      end
    end.join("\n")
  end
end

class FormalizeSpecClient
  include Crig::Client::CompletionClient(FormalizeSpecCompletionModel)

  def initialize(@responses : Array(String), @prompts : Array(String))
  end

  def completion_model(model : String) : FormalizeSpecCompletionModel
    FormalizeSpecCompletionModel.new(@responses, @prompts)
  end
end
