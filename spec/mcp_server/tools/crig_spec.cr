require "../../spec_helper"

private def with_env_unset(name : String, &)
  previous = ENV[name]?
  ENV.delete(name)
  yield
ensure
  if previous
    ENV[name] = previous
  else
    ENV.delete(name)
  end
end

describe Chiasmus::MCPServer::Tools::CrigTool do
  describe "#invoke" do
    it "requires a prompt" do
      tool = Chiasmus::MCPServer::Tools::CrigTool.new
      result = tool.invoke({} of String => JSON::Any)

      result.status.should eq("error")
      result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("prompt")
    end

    pending "returns a configuration error when no API key is available" do
      tool = Chiasmus::MCPServer::Tools::CrigTool.new

      prev_openai = ENV["OPENAI_API_KEY"]?
      prev_deepseek = ENV["DEEPSEEK_API_KEY"]?
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("DEEPSEEK_API_KEY")
      begin
        result = tool.invoke({"prompt" => JSON::Any.new("hello")})

        result.status.should eq("error")
        result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("API key not configured")
      ensure
        ENV["OPENAI_API_KEY"] = prev_openai if prev_openai
        ENV["DEEPSEEK_API_KEY"] = prev_deepseek if prev_deepseek
      end
    end
  end
end
