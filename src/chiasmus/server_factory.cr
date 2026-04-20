# Server factory for creating provider-specific servers
require "crig"

module Chiasmus
  module MCPServer
    # Factory for creating provider-specific servers
    module Factory
      private def self.apply_optional_credentials(builder, api_key : String?, base_url : String?)
        configured_builder = builder
        configured_builder = configured_builder.api_key(api_key) if api_key
        configured_builder = configured_builder.base_url(base_url) if base_url
        configured_builder
      end

      # Create a server with OpenAI provider
      def self.openai(
        api_key : String? = ENV["OPENAI_API_KEY"]?,
        base_url : String? = ENV["OPENAI_BASE_URL"]?,
        model : String = Crig::Providers::OpenAI::GPT_4O_MINI,
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::OpenAI::Model)
        client = apply_optional_credentials(Crig::Providers::OpenAI::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with DeepSeek provider
      def self.deepseek(
        api_key : String? = ENV["DEEPSEEK_API_KEY"]?,
        base_url : String? = ENV["DEEPSEEK_BASE_URL"]?,
        model : String = Crig::Providers::DeepSeek::DEEPSEEK_CHAT,
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::DeepSeek::Model)
        client = apply_optional_credentials(Crig::Providers::DeepSeek::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Anthropic provider
      def self.anthropic(
        api_key : String? = ENV["ANTHROPIC_API_KEY"]?,
        base_url : String? = ENV["ANTHROPIC_BASE_URL"]?,
        model : String = Crig::Providers::Anthropic::CLAUDE_3_5_SONNET,
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Anthropic::Model)
        client = apply_optional_credentials(Crig::Providers::Anthropic::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Gemini provider
      def self.gemini(
        api_key : String? = ENV["GEMINI_API_KEY"]?,
        base_url : String? = ENV["GEMINI_BASE_URL"]?,
        model : String = "gemini-2.0-flash-exp",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Gemini::Model)
        client = apply_optional_credentials(Crig::Providers::Gemini::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Groq provider
      def self.groq(
        api_key : String? = ENV["GROQ_API_KEY"]?,
        base_url : String? = ENV["GROQ_BASE_URL"]?,
        model : String = "llama-3.3-70b",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Groq::Model)
        client = apply_optional_credentials(Crig::Providers::Groq::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Ollama provider
      def self.ollama(
        api_key : String? = ENV["OLLAMA_API_KEY"]?,
        base_url : String? = ENV["OLLAMA_BASE_URL"]?,
        model : String = "llama3.2",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Ollama::Model)
        client = apply_optional_credentials(Crig::Providers::Ollama::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Mistral provider
      def self.mistral(
        api_key : String? = ENV["MISTRAL_API_KEY"]?,
        base_url : String? = ENV["MISTRAL_BASE_URL"]?,
        model : String = "mistral-large-2411",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Mistral::Model)
        client = apply_optional_credentials(Crig::Providers::Mistral::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Cohere provider
      def self.cohere(
        api_key : String? = ENV["COHERE_API_KEY"]?,
        base_url : String? = ENV["COHERE_BASE_URL"]?,
        model : String = "command-r-plus-08-2024",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      ) : Server(Crig::Providers::Cohere::Model)
        client = apply_optional_credentials(Crig::Providers::Cohere::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server based on environment configuration
      def self.from_env : Server(Crig::Providers::OpenAI::Model)
        provider = ENV["CHIASMUS_LLM_PROVIDER"]? || "openai"
        model = ENV["CHIASMUS_LLM_MODEL"]? || Crig::Providers::OpenAI::GPT_4O_MINI
        server_for_provider(provider, model)
      end

      private def self.server_for_provider(provider : String, model : String) : Server(Crig::Providers::OpenAI::Model)
        case provider.downcase
        when "openai"
          openai(model: model)
        when "deepseek"
          deepseek(model: model)
        when "anthropic"
          anthropic(model: model)
        when "gemini"
          gemini(model: model)
        when "groq"
          groq(model: model)
        when "ollama"
          ollama(model: model)
        when "mistral"
          mistral(model: model)
        when "cohere"
          cohere(model: model)
        else
          openai(model: model)
        end
      end
    end
  end
end
