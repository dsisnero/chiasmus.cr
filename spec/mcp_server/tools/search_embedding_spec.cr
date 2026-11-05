require "../../spec_helper"
require "../../../src/chiasmus/mcp_server/tools/search"
require "../../../src/chiasmus/mcp_server/types"

KEYS = ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "CHIASMUS_EMBED_PROVIDER", "CHIASMUS_EMBED_MODEL", "CHIASMUS_EMBED_URL", "CHIASMUS_LOCAL_EMBED"]

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
  it "returns warning-bearing errors for unreadable files" do
    missing = File.join(Dir.tempdir, "search-missing-#{Random::Secure.hex(8)}.cr")
    result = Chiasmus::MCPServer::Tools::SearchTool.new.invoke({
      "query" => JSON::Any.new("find"),
      "files" => JSON.parse([missing].to_json),
    })

    result.should be_a(Chiasmus::MCPServer::Types::SearchErrorResponse)
    error = result.as(Chiasmus::MCPServer::Types::SearchErrorResponse)
    error.error.should eq("No readable files in `files`.")
    error.warnings.first.should contain(missing)
  end

  it "validates raw query and files before embedding configuration" do
    tool = Chiasmus::MCPServer::Tools::SearchTool.new

    missing = tool.invoke({} of String => JSON::Any)
    missing.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'query' (non-empty string) is required")

    whitespace = tool.invoke({
      "query" => JSON::Any.new("  "),
      "files" => JSON.parse(%(["/abs/src/a.cr"])),
    })
    whitespace.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'query' (non-empty string) is required")

    mixed_files = tool.invoke({
      "query" => JSON::Any.new("find me"),
      "files" => JSON.parse(%(["/abs/src/a.cr", 42, null])),
    })
    mixed_files.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'files' (non-empty array of absolute paths) is required")
  end

  describe "embedding provider resolution" do
    it "does not auto-select DeepSeek, which has no embeddings API" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-test",
        "OPENAI_API_KEY"          => nil,
        "OPENROUTER_API_KEY"      => nil,
        "CHIASMUS_EMBED_PROVIDER" => nil,
        "CHIASMUS_EMBED_URL"      => nil,
      }) do
        # Upstream warns and returns null rather than producing a confusing 404.
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("ollama")
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

    it "prefers OpenAI over DeepSeek when both keys are set" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        "OPENAI_API_KEY"          => "sk-openai-test",
        "CHIASMUS_EMBED_PROVIDER" => nil,
        # Refused port: keeps key precedence deterministic on hosts where a
        # local Ollama would otherwise win.
        "CHIASMUS_EMBED_URL" => "http://127.0.0.1:1",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("openai")
      end
    end

    it "uses DeepSeek only when CHIASMUS_EMBED_URL points at an embeddings endpoint" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        "OPENAI_API_KEY"          => nil,
        "OPENROUTER_API_KEY"      => nil,
        "CHIASMUS_EMBED_PROVIDER" => "deepseek",
        "CHIASMUS_EMBED_URL"      => "http://localhost:11434/v1",
      }) do
        resolution = Chiasmus::MCPServer::Tools::SearchTool.resolve_embedding_resolution
        resolution.should_not be_nil
        resolution.try(&.provider).should eq("deepseek")
        resolution.try(&.base_url).should eq("http://localhost:11434/v1")
      end
    end

    it "explains that DeepSeek needs CHIASMUS_EMBED_URL" do
      with_env({
        "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        "CHIASMUS_EMBED_PROVIDER" => "deepseek",
        "CHIASMUS_EMBED_URL"      => nil,
      }) do
        message = Chiasmus::MCPServer::Tools::SearchTool.embedding_configuration_error(
          Chiasmus::Utils::Config.load
        )
        message.should_not be_nil
        message.not_nil!.should contain("CHIASMUS_EMBED_URL")
      end
    end

    it "supports OpenRouter when OPENROUTER_API_KEY is set" do
      with_env({
        "OPENROUTER_API_KEY"      => "sk-or-test",
        "OPENAI_API_KEY"          => nil,
        "DEEPSEEK_API_KEY"        => nil,
        "CHIASMUS_EMBED_PROVIDER" => nil,
        "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:1",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("openrouter")
      end
    end

    it "rejects an unsupported CHIASMUS_EMBED_PROVIDER with a supported-values message" do
      with_env({
        "CHIASMUS_EMBED_PROVIDER" => "bogus",
      }) do
        message = Chiasmus::MCPServer::Tools::SearchTool.explicit_embedding_configuration_error
        message.should_not be_nil
        message.not_nil!.should contain("Unsupported CHIASMUS_EMBED_PROVIDER")
        message.not_nil!.should contain("ollama")
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

    it "reserves the node-llama diagnostic for the Node-only environment flag" do
      config = Chiasmus::Utils::Config::ChiasmusConfig.new(
        Chiasmus::Utils::Config::LocalEmbeddingsConfig.new(enabled: true, model: "hf:example/model")
      )

      Chiasmus::MCPServer::Tools::SearchTool.local_embedding_configuration_error(config).should be_nil
    end

    it "uses an enabled configured model through the Ollama embedding provider" do
      config = Chiasmus::Utils::Config::ChiasmusConfig.new(
        Chiasmus::Utils::Config::LocalEmbeddingsConfig.new(enabled: true, model: "nomic-embed-text")
      )

      resolution = Chiasmus::MCPServer::Tools::SearchTool.resolve_embedding_resolution(config)
      resolution.should_not be_nil
      resolution.try(&.provider).should eq("ollama")
      resolution.try(&.model_name).should eq("nomic-embed-text")
      Chiasmus::MCPServer::Tools::SearchTool.embedding_configured?(config).should be_true
    end

    it "isolates embedding caches by provider and model as well as dimension" do
      home = "/tmp/chiasmus-embedding-cache-path"
      openai = Chiasmus::MCPServer::Tools::SearchTool::EmbeddingResolution.new("openai", "text-embedding-3-small")
      ollama = Chiasmus::MCPServer::Tools::SearchTool::EmbeddingResolution.new("ollama", "nomic-embed-text")

      Chiasmus::MCPServer::Tools::SearchTool.embedding_cache_path(home, openai, 768).should_not eq(
        Chiasmus::MCPServer::Tools::SearchTool.embedding_cache_path(home, ollama, 768)
      )
    end
  end

  describe "embedding capability gate" do
    it "prefers a reachable local Ollama over ambient API keys" do
      server = HTTP::Server.new do |context|
        context.response.content_type = "application/json"
        context.response.print({models: [{name: "nomic-embed-text:latest"}]}.to_json)
      end
      address = server.bind_tcp(0)
      spawn { server.listen rescue nil }

      begin
        with_env({
          "CHIASMUS_EMBED_PROVIDER" => nil,
          "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:#{address.port}",
          "CHIASMUS_EMBED_MODEL"    => nil,
          "OPENAI_API_KEY"          => "sk-openai-test",
          "OPENROUTER_API_KEY"      => nil,
          "DEEPSEEK_API_KEY"        => "sk-deepseek-test",
        }) do
          Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("ollama")
          Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_model_name.should eq("nomic-embed-text")
          Chiasmus::MCPServer::Tools::SearchTool.embedding_configured?.should be_true
        end
      ensure
        server.close rescue nil
      end
    end

    it "falls back to an API key when the local Ollama lacks the model" do
      server = HTTP::Server.new do |context|
        context.response.content_type = "application/json"
        context.response.print({models: [{name: "llava:latest"}]}.to_json)
      end
      address = server.bind_tcp(0)
      spawn { server.listen rescue nil }

      begin
        with_env({
          "CHIASMUS_EMBED_PROVIDER" => nil,
          "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:#{address.port}",
          "CHIASMUS_EMBED_MODEL"    => nil,
          "OPENAI_API_KEY"          => "sk-openai-test",
          "OPENROUTER_API_KEY"      => nil,
          "DEEPSEEK_API_KEY"        => nil,
        }) do
          Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("openai")
        end
      ensure
        server.close rescue nil
      end
    end

    it "counts an explicit provider as configured without probing the network" do
      with_env({
        "CHIASMUS_EMBED_PROVIDER" => "ollama",
        "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:1",
        "OPENAI_API_KEY"          => nil,
        "OPENROUTER_API_KEY"      => nil,
        "DEEPSEEK_API_KEY"        => nil,
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.embedding_configured?.should be_true
      end
    end

    it "treats an unreachable implicit Ollama endpoint as not configured" do
      # 127.0.0.1:1 is refused immediately, so this stays hermetic on hosts that
      # do run Ollama on the default port.
      with_env({
        "CHIASMUS_EMBED_PROVIDER" => nil,
        "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:1",
        "OPENAI_API_KEY"          => nil,
        "OPENROUTER_API_KEY"      => nil,
        "DEEPSEEK_API_KEY"        => nil,
      }) do
        Chiasmus::MCPServer::Tools::SearchTool.embedding_configured?.should be_false
      end
    end

    it "reports the missing Ollama model in the configuration error" do
      with_env({
        "CHIASMUS_EMBED_PROVIDER" => nil,
        "CHIASMUS_EMBED_URL"      => "http://127.0.0.1:1",
        "OPENAI_API_KEY"          => nil,
        "OPENROUTER_API_KEY"      => nil,
        "DEEPSEEK_API_KEY"        => nil,
      }) do
        message = Chiasmus::MCPServer::Tools::SearchTool.embedding_configuration_error(
          Chiasmus::Utils::Config.load
        )
        message.should_not be_nil
        message.not_nil!.should contain("nomic-embed-text")
        message.not_nil!.should contain("ollama pull")
      end
    end

    it "matches Ollama model tags with and without the :latest suffix" do
      with_env({
        "CHIASMUS_EMBED_URL" => "http://127.0.0.1:1",
      }) do
        Chiasmus::MCPServer::Tools::SearchTool
          .ollama_embedding_available?("http://127.0.0.1:1", "nomic-embed-text")
          .should be_false
      end
    end
  end
end
