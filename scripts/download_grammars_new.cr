#!/usr/bin/env crystal

# This script uses the new chiasmus-grammar CLI to download and compile grammars
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
  puts "Downloading and compiling required grammars using chiasmus-grammar CLI..."
  puts "This script provides backward compatibility with the old download_grammars.cr"
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
    
    # Determine package name based on language
    package_name = case language
    when "ruby"       then "tree-sitter-ruby"
    when "python"     then "tree-sitter-python"
    when "java"       then "tree-sitter-java"
    when "go"         then "tree-sitter-go"
    when "rust"       then "tree-sitter-rust"
    when "scala"      then "tree-sitter-scala"
    when "javascript" then "tree-sitter-javascript"
    when "typescript" then "tree-sitter-typescript"
    when "tsx"        then "tree-sitter-typescript"
    when "crystal"    then "tree-sitter-crystal"
    else                   nil
    end
    
    if package_name
      # Use the new CLI to add the grammar
      if run_command("bin/chiasmus-grammar", ["add", package_name])
        success_count += 1
        puts "  ✓ #{language} (#{package_name})"
      else
        fail_count += 1
        puts "  ✗ #{language} (#{package_name})"
      end
    else
      puts "  ⚠ No package mapping for #{language}"
      fail_count += 1
    end
    
    puts
  end
  
  puts "=" * 60
  puts "Summary:"
  puts "  Successfully installed: #{success_count}/#{DEFAULT_LANGUAGES.size}"
  puts "  Failed: #{fail_count}/#{DEFAULT_LANGUAGES.size}"
  puts
  
  if fail_count > 0
    puts "⚠ Warning: Some grammars failed to install!"
    puts "The static binary may not include all required parsers."
    exit 1
  else
    puts "✅ All required grammars successfully downloaded and compiled!"
    
    # Show status
    puts
    puts "Installed grammars:"
    run_command("bin/chiasmus-grammar", ["status"])
  end
end

main