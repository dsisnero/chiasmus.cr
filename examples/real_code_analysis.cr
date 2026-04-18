#!/usr/bin/env crystal
# Real example: Analyze this codebase with tree-sitter + Prolog
# Shows how chiasmus can answer questions about code structure

require "../src/chiasmus"
require "json"

puts "🔍 Real Codebase Analysis with Chiasmus"
puts "=" * 60

# Step 1: Analyze the codebase using tree-sitter graph tool
puts "\n📊 Step 1: Analyzing codebase with tree-sitter..."
tool = Chiasmus::MCPServer::Tools::GraphTool.new

# Analyze a few Crystal files from this project
files = [
  "./src/chiasmus.cr",
  "./src/chiasmus/formalize/engine.cr",
  "./src/chiasmus/solvers/z3_solver.cr",
  "./src/chiasmus/solvers/prolog_solver.cr"
].select { |f| File.exists?(f) }

if files.empty?
  puts "❌ No files found to analyze"
  exit 1
end

puts "  Analyzing #{files.size} files:"
files.each { |f| puts "    - #{f}" }

result = tool.invoke({
  "files"    => JSON::Any.new(files.map { |f| JSON::Any.new(f) }),
  "analysis" => JSON::Any.new("facts"),
})

if result["status"]?.try(&.as_s) != "success"
  puts "❌ Failed to analyze codebase: #{result["error"]?.try(&.as_s)}"
  exit 1
end

prolog_facts = result["result"]?.try(&.as_s) || ""
puts "  ✓ Extracted #{prolog_facts.lines.size} lines of Prolog facts"

# Step 2: Create Prolog queries to answer questions about the codebase
puts "\n🤔 Step 2: Answering questions about the codebase..."

# Question 1: What functions are defined?
puts "\n1. What functions are defined in these files?"
prolog_program_1 = prolog_facts + "\n\n?- findall((File,Name,Line), defines(File, Name, function, Line), Definitions)."

solver = Chiasmus::Solvers::PrologSolver.new
input_1 = Chiasmus::Solvers::PrologSolverInput.new(
  program: prolog_program_1,
  query: "findall((File,Name,Line), defines(File, Name, function, Line), Definitions)"
)

result_1 = solver.solve(input_1)

if result_1.is_a?(Chiasmus::Solvers::SuccessResult)
  success_1 = result_1.as(Chiasmus::Solvers::SuccessResult)
  if success_1.answers.empty?
    puts "   No functions found (unexpected!)"
  else
    puts "   Found #{success_1.answers.size} function(s):"
    success_1.answers.each_with_index do |answer, i|
      # Parse the answer which looks like: Definitions=[(...), (...)]
      if answer.formatted.includes?("Definitions=")
        # Extract the list
        list_str = answer.formatted.split("Definitions=").last
        # Simple parsing - in real use we'd parse this properly
        puts "   - #{answer.formatted[0..100]}..."
      else
        puts "   #{i + 1}. #{answer.formatted}"
      end
    end
  end
else
  puts "   Error: #{result_1}"
end

# Question 2: What calls the 'solve' function?
puts "\n2. What functions call 'solve'?"
prolog_program_2 = prolog_facts + "\n\n?- findall(Caller, calls(Caller, 'solve'), Callers)."

input_2 = Chiasmus::Solvers::PrologSolverInput.new(
  program: prolog_program_2,
  query: "findall(Caller, calls(Caller, 'solve'), Callers)"
)

result_2 = solver.solve(input_2)

if result_2.is_a?(Chiasmus::Solvers::SuccessResult)
  success_2 = result_2.as(Chiasmus::Solvers::SuccessResult)
  if success_2.answers.empty?
    puts "   No callers of 'solve' found"
  else
    puts "   Found #{success_2.answers.size} caller(s) of 'solve':"
    success_2.answers.each do |answer|
      puts "   - #{answer.formatted}"
    end
  end
else
  puts "   Error or no results: #{result_2.class}"
end

# Question 3: Are there any dead functions?
puts "\n3. Are there any dead functions (defined but not called)?"
prolog_program_3 = prolog_facts + "\n\n?- findall(Name, dead(Name), DeadFunctions)."

input_3 = Chiasmus::Solvers::PrologSolverInput.new(
  program: prolog_program_3,
  query: "findall(Name, dead(Name), DeadFunctions)"
)

result_3 = solver.solve(input_3)

if result_3.is_a?(Chiasmus::Solvers::SuccessResult)
  success_3 = result_3.as(Chiasmus::Solvers::SuccessResult)
  if success_3.answers.empty?
    puts "   No dead functions found (good!)"
  else
    puts "   Found #{success_3.answers.size} dead function(s):"
    success_3.answers.each do |answer|
      puts "   - #{answer.formatted}"
    end
  end
else
  puts "   Error or no results: #{result_3.class}"
end

# Question 4: Show call relationships
puts "\n4. Show some call relationships:"
prolog_program_4 = prolog_facts + "\n\n?- calls(Caller, Callee)."

input_4 = Chiasmus::Solvers::PrologSolverInput.new(
  program: prolog_program_4,
  query: "calls(Caller, Callee)"
)

result_4 = solver.solve(input_4)

if result_4.is_a?(Chiasmus::Solvers::SuccessResult)
  success_4 = result_4.as(Chiasmus::Solvers::SuccessResult)
  if success_4.answers.empty?
    puts "   No call relationships found"
  else
    puts "   Found #{success_4.answers.size} call relationship(s) (showing first 5):"
    success_4.answers.first(5).each do |answer|
      puts "   - #{answer.formatted}"
    end
    if success_4.answers.size > 5
      puts "   ... and #{success_4.answers.size - 5} more"
    end
  end
else
  puts "   Error or no results: #{result_4.class}"
end

# Step 3: Demonstrate with DeepSeek integration
puts "\n🚀 Step 3: DeepSeek Integration Example"
puts "=" * 60

# Check if DeepSeek API key is available
if ENV["DEEPSEEK_API_KEY"]?
  puts "DeepSeek API key detected. To use DeepSeek to generate Prolog queries:"
  puts ""
  puts "1. Create a prompt with the Prolog facts:"
  puts "   #{prolog_facts.lines.first(3).join(" ")}... (#{prolog_facts.lines.size} lines total)"
  puts ""
  puts "2. Ask a question like: 'What functions import the JSON module?'"
  puts ""
  puts "3. DeepSeek would generate a Prolog query like:"
  puts "   ?- findall((File,Module), imports(File, 'JSON', _), Imports)."
  puts ""
  puts "4. Execute the query with the Prolog solver"
  puts ""
  puts "Example code for DeepSeek integration is in examples/deepseek_integration.cr"
else
  puts "DeepSeek API key not set. To enable DeepSeek integration:"
  puts "  export DEEPSEEK_API_KEY=your-api-key"
  puts ""
  puts "With DeepSeek, you could ask natural language questions like:"
  puts "  - 'What are the entry points of this system?'"
  puts "  - 'Show me all functions that call Z3 solver'"
  puts "  - 'Find code that handles error cases'"
  puts ""
  puts "DeepSeek would generate the appropriate Prolog queries automatically."
end

puts "\n✅ Analysis complete!"
puts ""
puts "Summary:"
puts "  - Tree-sitter extracted #{prolog_facts.lines.size} Prolog facts"
puts "  - Prolog solver answered questions about code structure"
puts "  - Can integrate with DeepSeek for natural language queries"
puts ""
puts "This demonstrates chiasmus as a powerful code analysis tool that combines:"
puts "  1. Tree-sitter for parsing code"
puts "  2. Prolog for logical reasoning about code structure"
puts "  3. DeepSeek (optional) for natural language interface"
puts "  4. Formal verification capabilities (Z3, Prolog solvers)"