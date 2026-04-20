#!/usr/bin/env crystal

# This script uses the new chiasmus-grammar CLI to set up required grammars
# It's a thin wrapper that provides backward compatibility

require "process"

# Default languages for static binary
DEFAULT_LANGUAGES = [
  "ruby",
  "python", 
  "java",
  "go",
  "rust",
  "scala",
  "javascript",
  "typescript",
  "tsx",
  "crystal"
]

def run_command(cmd : String, args : Array(String) = [] of String) : Bool
  puts "Running: #{cmd} #{args.join(" ")}" if ENV["DEBUG"]?
  
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(cmd, args,
    output: output,
    error: error
  )
  
  unless status.success?
    puts "Command failed: #{cmd} #{args.join(" ")}"
    puts "Error: #{error.to_s}" unless error.to_s.empty?
    return false
  end
  
  true
end

def main
  puts "Setting up required grammars using chiasmus-grammar CLI..."
  puts "This script provides backward compatibility with the old setup_grammars.cr"
  puts
  
  # Build the CLI if needed
  unless File.exists?("bin/chiasmus-grammar")
    puts "Building chiasmus-grammar CLI..."
    unless run_command("crystal", ["build", "--release", "-o", "bin/chiasmus-grammar", "src/chiasmus_grammar.cr"])
      puts "Failed to build chiasmus-grammar CLI"
      exit 1
    end
  end
  
  success_count = 0
  fail_count = 0
  
  DEFAULT_LANGUAGES.each do |language|
    puts "Processing #{language}..."
    
    # Use the new CLI to add/compile the grammar
    if run_command("bin/chiasmus-grammar", ["compile", language])
      success_count += 1
      puts "  ✓ #{language}"
    else
      fail_count += 1
      puts "  ✗ #{language}"
    end
    
    puts
  end
  
  puts "=" * 60
  puts "Summary:"
  puts "  Successfully compiled: #{success_count}/#{DEFAULT_LANGUAGES.size}"
  puts "  Failed: #{fail_count}/#{DEFAULT_LANGUAGES.size}"
  puts
  
  if fail_count > 0
    puts "⚠ Warning: Some grammars failed to compile!"
    puts "The static binary may not include all required parsers."
    exit 1
  else
    puts "✅ All required grammars are available!"
  end
end

main