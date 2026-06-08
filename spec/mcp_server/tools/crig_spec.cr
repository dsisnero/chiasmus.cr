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

    it "returns a configuration error when no API key is available" do
      tool = Chiasmus::MCPServer::Tools::CrigTool.new

      with_env_unset("OPENAI_API_KEY") do
        result = tool.invoke({"prompt" => JSON::Any.new("hello")})

        result.status.should eq("error")
        result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("API key not configured")
      end
    end
  end
end
