#!/usr/bin/env crystal
# Chiasmus Rig Integration Example
# Shows how to use chiasmus as a Crig tool with DeepSeek

require "../src/chiasmus"

# ============================================================================
# Configuration
# ============================================================================
puts "Configuring DeepSeek..."

# Method 1: Simple configuration
ENV["DEEPSEEK_API_KEY"] = ENV["DEEPSEEK_API_KEY"]? || begin
  print "Enter your DeepSeek API key: "
  gets.try(&.strip) || ""
end

Chiasmus::LLM.configure(
  provider: "deepseek",
  model: Crig::Providers::DeepSeek::DEEPSEEK_CHAT
)

# ============================================================================
# Create chiasmus-enhanced agent
# ============================================================================
puts "Creating chiasmus-enhanced agent..."

# Get the configured agent
agent = Chiasmus::LLM.agent
unless agent
  puts "Error: No LLM agent available. Check your API key."
  exit 1
end

# Create chiasmus agent wrapper
chiasmus_agent = Chiasmus::ChiasmusAgent.new(agent)

# ============================================================================
# Interactive REPL
# ============================================================================
if ARGV.empty? || ARGV[0] == "repl"
  puts "\nStarting Chiasmus Agent REPL with DeepSeek..."
  chiasmus_agent.repl
  exit 0
end

# ============================================================================
# Batch test problems
# ============================================================================
if ARGV[0] == "test"
  puts "\nRunning integration tests..."

  test_problems = [
    "Find x such that x + 5 = 10",
    "All men are mortal. Socrates is a man. Is Socrates mortal?",
    "Alice is older than Bob. Bob is older than Carol. Is Alice older than Carol?",
    "If it rains, the ground is wet. It is raining. Is the ground wet?",
    "x > 0 and x < 10, find possible integer values for x",
  ]

  test_problems.each_with_index do |problem, i|
    puts "\nTest #{i + 1}: #{problem}"
    puts "-" * 50

    begin
      result = chiasmus_agent.solve(problem)
      parsed = JSON.parse(result)

      if parsed["status"] == "success"
        puts "✓ Solved using #{parsed["template"]} (#{parsed["solver"]})"

        case parsed["result_type"]
        when "z3"
          if parsed["satisfiable"].as_bool
            puts "  Model: #{parsed["model"]}"
          else
            puts "  Unsatisfiable"
          end
        when "prolog"
          if parsed["success"].as_bool
            answers = parsed["answers"].as_a
            puts "  Found #{answers.size} answer(s)"
            answers.each_with_index do |answer, j|
              puts "  #{j + 1}. #{answer}"
            end
          else
            puts "  No solutions found"
          end
        end
      else
        puts "✗ Error: #{parsed["error"]}"
      end
    rescue ex
      puts "✗ Exception: #{ex.message}"
    end

    # Small delay between tests
    sleep 0.5 if i < test_problems.size - 1
  end

  puts "\nTests completed!"
  exit 0
end

# ============================================================================
# Solve single problem from command line
# ============================================================================
if ARGV[0] == "solve"
  problem = ARGV[1..].join(" ")
  unless problem.empty?
    puts "\nSolving: #{problem}"
    puts "-" * 50

    result = chiasmus_agent.solve(problem, debug: true)
    parsed = JSON.parse(result)

    puts JSON.pretty_generate(parsed)
  else
    puts "Error: No problem provided"
    puts "Usage: crystal examples/rig_integration.cr solve 'your problem here'"
  end
  exit 0
end

# ============================================================================
# Show usage
# ============================================================================
puts <<-USAGE
Chiasmus Rig Integration

Usage:
  crystal #{__FILE__} [command]

Commands:
  repl                    Start interactive REPL (default)
  test                    Run integration tests
  solve "problem"         Solve a single problem
  help                    Show this help

Examples:
  crystal #{__FILE__} repl
  crystal #{__FILE__} test
  crystal #{__FILE__} solve "Find x such that x + 5 = 10"

Configuration:
  Set DEEPSEEK_API_KEY environment variable or enter when prompted
  Can also use other providers: OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.
USAGE