require "crig"

module Chiasmus
  module LLM
    # Default configuration
    DEFAULT_PREAMBLE = "You are Chiasmus, a formal reasoning assistant that produces concise, exact outputs."

    # Simple configuration struct for basic usage
    struct SimpleConfig
      getter provider : String = "openai"
      getter api_key : String?
      getter base_url : String?
      getter model : String = Crig::Providers::OpenAI::GPT_4O_MINI
      getter preamble : String = DEFAULT_PREAMBLE

      def initialize(
        @provider : String = ENV["CHIASMUS_LLM_PROVIDER"]? || "openai",
        @api_key : String? = nil,
        @base_url : String? = nil,
        @model : String = ENV["CHIASMUS_LLM_MODEL"]? || Crig::Providers::OpenAI::GPT_4O_MINI,
        @preamble : String = DEFAULT_PREAMBLE,
      )
        # Try to get API key from environment if not provided
        if @api_key.nil?
          @api_key = case @provider.downcase
                     when "openai"    then ENV["OPENAI_API_KEY"]?
                     when "deepseek"  then ENV["DEEPSEEK_API_KEY"]?
                     when "anthropic" then ENV["ANTHROPIC_API_KEY"]?
                     when "gemini"    then ENV["GEMINI_API_KEY"]?
                     when "groq"      then ENV["GROQ_API_KEY"]?
                     when "ollama"    then ENV["OLLAMA_API_KEY"]?
                     when "mistral"   then ENV["MISTRAL_API_KEY"]?
                     when "cohere"    then ENV["COHERE_API_KEY"]?
                     else                  nil
                     end
        end

        # Try to get base URL from environment if not provided
        return unless @base_url.nil?

        @base_url = case @provider.downcase
                    when "openai"    then ENV["OPENAI_BASE_URL"]?
                    when "deepseek"  then ENV["DEEPSEEK_BASE_URL"]?
                    when "anthropic" then ENV["ANTHROPIC_BASE_URL"]?
                    when "gemini"    then ENV["GEMINI_BASE_URL"]?
                    when "groq"      then ENV["GROQ_BASE_URL"]?
                    when "ollama"    then ENV["OLLAMA_BASE_URL"]?
                    when "mistral"   then ENV["MISTRAL_BASE_URL"]?
                    when "cohere"    then ENV["COHERE_BASE_URL"]?
                    else                  nil
                    end
      end
    end

    # Check if LLM is available (has API key)
    def self.available?(config : SimpleConfig = SimpleConfig.new) : Bool
      config.api_key != nil
    end

    # ==========================================================================
    # Crig Builder API Exposure
    # ==========================================================================

    # Get a Crig client builder for a specific provider
    # This exposes the full Crig builder API for maximum flexibility
    module Builders
      # OpenAI client builder
      def self.openai(api_key : String? = ENV["OPENAI_API_KEY"]?, base_url : String? = ENV["OPENAI_BASE_URL"]?)
        builder = Crig::Providers::OpenAI::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # DeepSeek client builder
      def self.deepseek(api_key : String? = ENV["DEEPSEEK_API_KEY"]?, base_url : String? = ENV["DEEPSEEK_BASE_URL"]?)
        builder = Crig::Providers::DeepSeek::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Anthropic client builder
      def self.anthropic(api_key : String? = ENV["ANTHROPIC_API_KEY"]?, base_url : String? = ENV["ANTHROPIC_BASE_URL"]?)
        builder = Crig::Providers::Anthropic::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Gemini client builder
      def self.gemini(api_key : String? = ENV["GEMINI_API_KEY"]?, base_url : String? = ENV["GEMINI_BASE_URL"]?)
        builder = Crig::Providers::Gemini::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Groq client builder
      def self.groq(api_key : String? = ENV["GROQ_API_KEY"]?, base_url : String? = ENV["GROQ_BASE_URL"]?)
        builder = Crig::Providers::Groq::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Ollama client builder (Ollama doesn't use API keys)
      def self.ollama(api_key : String? = ENV["OLLAMA_API_KEY"]?, base_url : String? = ENV["OLLAMA_BASE_URL"]?)
        builder = Crig::Providers::Ollama::Client.builder
        # Ollama's api_key() method expects Crig::Nothing
        builder = builder.api_key(Crig::Nothing.new)
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Mistral client builder
      def self.mistral(api_key : String? = ENV["MISTRAL_API_KEY"]?, base_url : String? = ENV["MISTRAL_BASE_URL"]?)
        builder = Crig::Providers::Mistral::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Cohere client builder
      def self.cohere(api_key : String? = ENV["COHERE_API_KEY"]?, base_url : String? = ENV["COHERE_BASE_URL"]?)
        builder = Crig::Providers::Cohere::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        builder = builder.base_url(base_url.not_nil!) if base_url
        builder
      end

      # Azure OpenAI client builder
      def self.azure_openai(api_key : String? = ENV["AZURE_OPENAI_API_KEY"]?, base_url : String? = ENV["AZURE_OPENAI_BASE_URL"]?)
        builder = Crig::Providers::Azure::Client.builder
        builder = builder.api_key(api_key.not_nil!) if api_key
        # Azure uses azure_endpoint instead of base_url
        builder = builder.azure_endpoint(base_url.not_nil!) if base_url
        builder
      end
    end

    # ==========================================================================
    # Convenience Methods
    # ==========================================================================

    # Create a client from simple configuration (for backward compatibility)
    def self.client(config : SimpleConfig = SimpleConfig.new)
      case config.provider.downcase
      when "openai"
        Builders.openai(config.api_key, config.base_url).build
      when "deepseek"
        Builders.deepseek(config.api_key, config.base_url).build
      when "anthropic"
        Builders.anthropic(config.api_key, config.base_url).build
      when "gemini"
        Builders.gemini(config.api_key, config.base_url).build
      when "groq"
        Builders.groq(config.api_key, config.base_url).build
      when "ollama"
        Builders.ollama(config.api_key, config.base_url).build
      when "mistral"
        Builders.mistral(config.api_key, config.base_url).build
      when "cohere"
        Builders.cohere(config.api_key, config.base_url).build
      when "azure", "azure_openai"
        Builders.azure_openai(config.api_key, config.base_url).build
      else
        raise "Unsupported LLM provider: #{config.provider}. Use LLM::Builders directly for full control."
      end
    end

    # Create an agent from simple configuration (for backward compatibility)
    def self.agent(config : SimpleConfig = SimpleConfig.new)
      client(config).agent(config.model).preamble(config.preamble).build
    end

    # Configuration state
    class_property current_config : SimpleConfig = SimpleConfig.new

    # Configure with simple settings
    def self.configure(provider : String = "openai", model : String? = nil, api_key : String? = nil, base_url : String? = nil)
      @@current_config = SimpleConfig.new(
        provider: provider,
        api_key: api_key,
        base_url: base_url,
        model: model || case provider.downcase
        when "openai"    then Crig::Providers::OpenAI::GPT_4O_MINI
        when "deepseek"  then Crig::Providers::DeepSeek::DEEPSEEK_CHAT
        when "anthropic" then "claude-3-5-sonnet-20241022"
        when "gemini"    then "gemini-2.0-flash-exp"
        when "groq"      then "llama-3.3-70b"
        when "ollama"    then "llama3.2"
        when "mistral"   then "mistral-large-2411"
        when "cohere"    then "command-r-plus-08-2024"
        else                  Crig::Providers::OpenAI::GPT_4O_MINI
        end
      )
    end

    # Get or create agent based on current configuration
    # Returns an untyped agent (use factory methods for typed agents)
    def self.agent
      return nil unless available?(@@current_config)

      client = client(@@current_config)
      client.agent(@@current_config.model).preamble(@@current_config.preamble).build
    end

    # ==========================================================================
    # Example Usage:
    # ==========================================================================
    #
    # # Method 1: Simple configuration (backward compatible)
    # config = LLM::SimpleConfig.new(
    #   provider: "deepseek",
    #   model: Crig::Providers::DeepSeek::DEEPSEEK_CHAT
    # )
    # agent = LLM.agent(config)
    #
    # # Method 2: Full Crig builder API (recommended for flexibility)
    # client = LLM::Builders.deepseek
    #   .api_key("your-deepseek-api-key")
    #   .base_url("https://api.deepseek.com")
    #   .build
    #
    # agent = client
    #   .agent(Crig::Providers::DeepSeek::DEEPSEEK_CHAT)
    #   .preamble("You are Chiasmus...")
    #   .temperature(0.7)
    #   .max_tokens(4000)
    #   .build
    #
    # # Method 3: Direct Crig usage (maximum control)
    # require "crig"
    # client = Crig::Providers::DeepSeek::CompletionsClient.builder
    #   .api_key("your-key")
    #   .build
    # agent = client.agent("deepseek-chat").build
    # ==========================================================================
  end
end
