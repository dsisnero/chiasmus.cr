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
      )
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
      )
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
      )
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
      )
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
      )
        client = apply_optional_credentials(Crig::Providers::Groq::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Ollama provider (local, no API key needed)
      def self.ollama(
        api_key : String? = nil,
        base_url : String? = ENV["OLLAMA_BASE_URL"]?,
        model : String = "llama3.2",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      )
        client = Crig::Providers::Ollama::Client.builder
        client = client.base_url(base_url) if base_url
        client = client.build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server with Mistral provider
      def self.mistral(
        api_key : String? = ENV["MISTRAL_API_KEY"]?,
        base_url : String? = ENV["MISTRAL_BASE_URL"]?,
        model : String = "mistral-large-2411",
        preamble : String = LLM::DEFAULT_PREAMBLE,
      )
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
      )
        client = apply_optional_credentials(Crig::Providers::Cohere::Client.builder, api_key, base_url).build

        agent = client.agent(model).preamble(preamble).build
        Server.with_agent(agent)
      end

      # Create a server without an LLM agent — tools that need an LLM
      # degrade gracefully (chiasmus_formalize falls back to template search,
      # chiasmus_solve falls back to formalize, chiasmus_learn returns
      # "no LLM configured", chiasmus_crig returns "no API key").
      private def self.no_llm_server : Server(LLM::MockCompletionModel)
        server = Server(LLM::MockCompletionModel).new
        MCPServer::RUNTIME_LOCK.synchronize do
          MCPServer.current_server = server
        end
        server
      end

      # Create a server based on environment configuration.
      #
      # Uses the provider-specific API key to detect whether an LLM backend
      # is available. Falls back to a server without LLM when the key is
      # missing, so the MCP process still starts and responds to tools/list
      # (hiding chiasmus_learn). Matches upstream createLLMFromEnv() behaviour.
      def self.from_env
        provider = ENV["CHIASMUS_LLM_PROVIDER"]? || "deepseek"
        model = ENV["CHIASMUS_LLM_MODEL"]? || Crig::Providers::DeepSeek::DEEPSEEK_CHAT

        unless provider_api_key_set?(provider)
          STDERR.puts "[Chiasmus] No #{provider}_API_KEY set — starting without LLM"
          STDERR.puts "[Chiasmus] chiasmus_learn gated; formalize/solve degrade gracefully"
          return no_llm_server
        end

        server_for_provider(provider, model)
      rescue ex
        STDERR.puts "[Chiasmus] LLM unavailable: #{ex.message}"
        no_llm_server
      end

      private def self.provider_api_key_set?(provider : String) : Bool
        case provider.downcase
        when "openai"    then check_key(ENV["OPENAI_API_KEY"]?)
        when "deepseek"  then check_key(ENV["DEEPSEEK_API_KEY"]?)
        when "anthropic" then check_key(ENV["ANTHROPIC_API_KEY"]?)
        when "gemini"    then check_key(ENV["GEMINI_API_KEY"]?)
        when "groq"      then check_key(ENV["GROQ_API_KEY"]?)
        when "mistral"   then check_key(ENV["MISTRAL_API_KEY"]?)
        when "cohere"    then check_key(ENV["COHERE_API_KEY"]?)
        when "ollama"    then true # local, no API key needed
        else                  true # unknown provider; let it try
        end
      end

      private def self.check_key(val : String?) : Bool
        !val.nil? && !val.blank?
      end

      private def self.server_for_provider(provider : String, model : String)
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
