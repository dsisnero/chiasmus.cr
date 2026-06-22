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
      with_env_unset("OPENAI_API_KEY") do
        with_env_unset("DEEPSEEK_API_KEY") do
          tool = Chiasmus::MCPServer::Tools::CrigTool.new

          result = tool.invoke({"prompt" => JSON::Any.new("hello")})

          result.status.should eq("error")
          result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("API key not configured")
        end
      end
    end

    it "uses the async invocation boundary before returning" do
      with_env_unset("OPENAI_API_KEY") do
        with_env_unset("DEEPSEEK_API_KEY") do
          tool = Chiasmus::MCPServer::Tools::CrigTool.new
          entered = Channel(Bool).new(1)
          release = Channel(Bool).new(1)
          result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

          Chiasmus::MCPServer::Tools::CrigTool.set_before_async_result_send_hook_for_test do
            entered.send(true)
            release.receive
          end

          spawn do
            result_chan.send(tool.invoke({"prompt" => JSON::Any.new("hello")}))
          end

          Chiasmus::Utils::Timeout.with_timeout_async(250, entered).should eq(true)

          select
          when result_chan.receive?
            fail("expected crig tool to wait on async boundary")
          else
          end

          release.send(true)
          result = Chiasmus::Utils::Timeout.with_timeout_async(250, result_chan)
          result.should_not be_nil
          result.not_nil!.status.should eq("error")
          result.not_nil!.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("API key not configured")
        ensure
          Chiasmus::MCPServer::Tools::CrigTool.clear_before_async_result_send_hook_for_test
        end
      end
    end
  end
end
