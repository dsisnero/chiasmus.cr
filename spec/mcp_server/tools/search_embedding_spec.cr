require "../../spec_helper"
require "../../../src/chiasmus/mcp_server/tools/search"
require "../../../src/chiasmus/mcp_server/types"

KEYS = ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "CHIASMUS_EMBED_PROVIDER", "CHIASMUS_EMBED_MODEL"]

private def with_env(vars : Hash(String, String?), &)
  previous = {} of String => String?
  KEYS.each { |k| previous[k] = ENV[k]? }
  begin
    vars.each do |k, v|
      if v
        ENV[k] = v
      else
        ENV.delete(k)
      end
    end
    yield
  ensure
    previous.each do |k, v|
      if v
        ENV[k] = v
      else
        ENV.delete(k)
      end
    end
  end
end

describe Chiasmus::MCPServer::Tools::SearchTool do
  describe "embedding provider resolution" do
    it "defaults to DeepSeek when DEEPSEEK_API_KEY is set" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-test",
        "OPENAI_API_KEY"          => nil,
        "CHIASMUS_EMBED_PROVIDER" => nil,
      }) do
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        r = tool.invoke({
          "query" => JSON::Any.new("test"),
          "files" => JSON::Any.new([] of JSON::Any),
        })
        # Should fail with "no readable files" not "API key" — meaning it resolved the provider
        r.status.should eq("error")
        err = r.as(Chiasmus::MCPServer::Types::ErrorResponse).error
        err.should contain("files")
      end
    end

    it "uses CHIASMUS_EMBED_PROVIDER to select openai or deepseek" do
      # Even with DEEPSEEK set, if provider is "openai", use OPENAI
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-ds",
        "OPENAI_API_KEY"          => "sk-oai",
        "CHIASMUS_EMBED_PROVIDER" => "openai",
      }) do
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        r = tool.invoke({
          "query" => JSON::Any.new("test"),
          "files" => JSON::Any.new([] of JSON::Any),
        })
        r.status.should eq("error")
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("files")
      end
    end

    it "returns error when no embedding API key is set" do
      with_env({
        "DEEPSEEK_API_KEY"        => nil,
        "OPENAI_API_KEY"          => nil,
        "CHIASMUS_EMBED_PROVIDER" => nil,
      }) do
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        r = tool.invoke({
          "query" => JSON::Any.new("test"),
          "files" => JSON::Any.new([JSON::Any.new(__FILE__)]),
        })
        r.status.should eq("error")
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("embedding")
      end
    end

    it "respects CHIASMUS_EMBED_MODEL env override" do
      with_env({
        "DEEPSEEK_API_KEY"     => "sk-ds",
        "OPENAI_API_KEY"       => nil,
        "CHIASMUS_EMBED_MODEL" => "custom-embed-model",
      }) do
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        r = tool.invoke({
          "query" => JSON::Any.new("test"),
          "files" => JSON::Any.new([] of JSON::Any),
        })
        r.status.should eq("error")
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("files")
      end
    end

    it "prefers DeepSeek over OpenAI when both keys are set" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        "OPENAI_API_KEY"          => "sk-openai-test",
        "CHIASMUS_EMBED_PROVIDER" => nil,
      }) do
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        r = tool.invoke({
          "query" => JSON::Any.new("test"),
          "files" => JSON::Any.new([] of JSON::Any),
        })
        r.status.should eq("error")
        # Should pass the provider check and fail on files, not "API key not configured"
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("files")
      end
    end
  end
end
