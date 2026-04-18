#!/usr/bin/env crystal
# Example: Using Chiasmus with DeepSeek provider

require "../src/chiasmus"

# Method 1: Using the factory pattern
puts "=== Method 1: Factory Pattern ==="

# Create a server with DeepSeek provider
# Note: You need to set DEEPSEEK_API_KEY environment variable
server = Chiasmus::MCPServer::Factory.deepseek(
  # api_key: "your-deepseek-api-key", # Or set DEEPSEEK_API_KEY env var
  # base_url: "https://api.deepseek.com", # Optional
  model: "deepseek-chat",
  preamble: "You are Chiasmus, a formal reasoning assistant."
)

puts "Created server with DeepSeek provider"
puts "Server type: #{server.class}"
puts "Formalization engine available: #{server.formalization_engine != nil}"

# Method 2: Using the main entry point with environment variables
puts "\n=== Method 2: Environment Configuration ==="
puts "Set environment variables:"
puts "  export CHIASMUS_LLM_PROVIDER=deepseek"
puts "  export DEEPSEEK_API_KEY=your-api-key"
puts "  export CHIASMUS_LLM_MODEL=deepseek-chat"
puts "Then run: crystal run src/chiasmus.cr"

# Method 3: Using RigTool with DeepSeek
puts "\n=== Method 3: RigTool Integration ==="

# Create a DeepSeek client directly
require "crig"

begin
  client = Crig::Providers::DeepSeek::Client.builder
    # .api_key("your-deepseek-api-key")
    # .base_url("https://api.deepseek.com")
    .build

  agent = client.agent("deepseek-chat")
    .preamble("You are Chiasmus, a formal reasoning assistant.")
    .build

  # Create RigTool with the agent
  tool = Chiasmus::RigTool(Crig::Providers::DeepSeek::Model).new(agent)

  puts "Created RigTool with DeepSeek agent"
  puts "Tool name: #{tool.name}"

  # Create ChiasmusAgent for REPL
  chiasmus_agent = Chiasmus::ChiasmusAgent(Crig::Providers::DeepSeek::Model).new(agent)
  puts "Created ChiasmusAgent wrapper"

rescue ex
  puts "Note: DeepSeek client creation failed (API key not set): #{ex.message}"
  puts "Set DEEPSEEK_API_KEY environment variable to test this example"
end

# Method 4: Running the MCP server
puts "\n=== Method 4: MCP Server ==="
puts "To run the MCP server with DeepSeek:"
puts <<-TEXT
  # Set environment variables
  export CHIASMUS_LLM_PROVIDER=deepseek
  export DEEPSEEK_API_KEY=your-api-key

  # Run the server
  crystal run src/chiasmus.cr
TEXT

puts "\n=== Summary ==="
puts "Chiasmus now supports multiple LLM providers through Crig:"
puts "  • OpenAI (default)"
puts "  • DeepSeek"
puts "  • Anthropic"
puts "  • Gemini"
puts "  • Groq"
puts "  • Ollama"
puts "  • Mistral"
puts "  • Cohere"
puts ""
puts "Use Chiasmus::MCPServer::Factory for provider-specific servers"
puts "Use Chiasmus::RigTool(M) for Crig tool integration"
puts "Use Chiasmus::ChiasmusAgent(M) for agent REPL functionality"