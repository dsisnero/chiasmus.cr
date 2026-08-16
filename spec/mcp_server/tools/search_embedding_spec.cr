require "../../spec_helper"
require "../../../src/chiasmus/mcp_server/tools/search"
require "../../../src/chiasmus/mcp_server/types"

KEYS = ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "CHIASMUS_EMBED_PROVIDER", "CHIASMUS_EMBED_MODEL", "CHIASMUS_LOCAL_EMBED"]

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
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("deepseek")
      end
    end

    it "uses CHIASMUS_EMBED_PROVIDER to select openai or deepseek" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-ds",
        "OPENAI_API_KEY"          => "sk-oai",
        "CHIASMUS_EMBED_PROVIDER" => "openai",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("openai")
      end
    end

    it "defaults to ollama when CHIASMUS_EMBED_PROVIDER is not set" do
      with_env({
        "DEEPSEEK_API_KEY"        => nil,
        "OPENAI_API_KEY"          => nil,
        "CHIASMUS_EMBED_PROVIDER" => nil,
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("ollama")
      end
    end

    it "returns error when no API key for non-ollama provider" do
      with_env({
        "DEEPSEEK_API_KEY"        => nil,
        "OPENAI_API_KEY"          => nil,
        "CHIASMUS_EMBED_PROVIDER" => "deepseek",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolve_embedding_resolution.should be_nil
      end
    end

    it "respects CHIASMUS_EMBED_MODEL env override" do
      with_env({
        "DEEPSEEK_API_KEY"     => "sk-ds",
        "OPENAI_API_KEY"       => nil,
        "CHIASMUS_EMBED_MODEL" => "custom-embed-model",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_model_name.should eq("custom-embed-model")
      end
    end

    it "prefers DeepSeek over OpenAI when both keys are set" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        "OPENAI_API_KEY"          => "sk-openai-test",
        "CHIASMUS_EMBED_PROVIDER" => nil,
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("deepseek")
      end
    end

    it "explains that node-llama local embedding configuration is unsupported" do
      with_env({
        "CHIASMUS_LOCAL_EMBED" => "1",
      }) do
        message = Chiasmus::MCPServer::Tools::SearchTool.local_embedding_configuration_error ||
                  raise "expected unsupported local embedding configuration error"
        message.downcase.should contain("not supported")
        message.should contain("CHIASMUS_EMBED_PROVIDER=ollama")
      end
    end

    it "rejects node-llama configuration loaded from config.json too" do
      config = Chiasmus::Utils::Config::ChiasmusConfig.new(
        Chiasmus::Utils::Config::LocalEmbeddingsConfig.new(enabled: true, model: "hf:example/model")
      )

      message = Chiasmus::MCPServer::Tools::SearchTool.local_embedding_configuration_error(config) ||
                raise "expected unsupported local embedding configuration error"
      message.downcase.should contain("not supported")
    end
  end
end
