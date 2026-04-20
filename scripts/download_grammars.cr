#!/usr/bin/env crystal

require "file_utils"
require "process"

# Required languages for static binary
REQUIRED_LANGUAGES = [
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

# Package names for each language
PACKAGE_MAP = {
  "ruby"       => "tree-sitter-ruby",
  "python"     => "tree-sitter-python",
  "java"       => "tree-sitter-java",
  "go"         => "tree-sitter-go",
  "rust"       => "tree-sitter-rust",
  "scala"      => "tree-sitter-scala",
  "javascript" => "tree-sitter-javascript",
  "typescript" => "tree-sitter-typescript",
  "tsx"        => "tree-sitter-typescript",
  "crystal"    => "tree-sitter-crystal",
}

# Vendor directory
VENDOR_DIR = File.expand_path("vendor/grammars", __DIR__)
Dir.mkdir_p(VENDOR_DIR)

def download_and_compile(language : String, package : String)
  puts "Processing #{language} (#{package})..."
  
  target_dir = File.join(VENDOR_DIR, package)
  
  # Check if already exists
  if Dir.exists?(target_dir)
    puts "  ✓ Already exists in vendor"
    
    # Check if compiled library exists
    ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
    lib_name = "libtree-sitter-#{language}.#{ext}"
    lib_path = File.join(target_dir, lib_name)
    
    if File.exists?(lib_path)
      puts "  ✓ Compiled library exists"
      return true
    else
      puts "  ✗ No compiled library, attempting to compile..."
    end
  else
    puts "  Downloading from GitHub..."
    
    # Clone repository
    repo_url = "https://github.com/tree-sitter/#{package}.git"
    success = Process.run("git", ["clone", "--depth", "1", repo_url, target_dir], 
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    ).success?
    
    unless success
      puts "  ✗ Failed to clone #{package}"
      return false
    end
  end
  
  # Compile the grammar
  puts "  Compiling #{language} grammar..."
  
  Dir.cd(target_dir) do
    # For TypeScript/TSX, need to compile in subdirectories
    if language == "typescript"
      compile_subdir = File.join(target_dir, "typescript")
      unless compile_grammar(compile_subdir, language)
        puts "  ✗ Failed to compile TypeScript"
        return false
      end
    elsif language == "tsx"
      compile_subdir = File.join(target_dir, "tsx")
      unless compile_grammar(compile_subdir, language)
        puts "  ✗ Failed to compile TSX"
        return false
      end
    else
      unless compile_grammar(target_dir, language)
        puts "  ✗ Failed to compile #{language}"
        return false
      end
    end
  end
  
  puts "  ✓ Successfully compiled #{language}"
  true
end

def compile_grammar(source_dir : String, language : String) : Bool
  Dir.cd(source_dir) do
    # Check for tree-sitter CLI
    unless system("which tree-sitter > /dev/null 2>&1")
      puts "    ✗ tree-sitter CLI not found"
      return false
    end
    
    # Check for C compiler
    unless system("which cc > /dev/null 2>&1") || system("which gcc > /dev/null 2>&1") || system("which clang > /dev/null 2>&1")
      puts "    ✗ C compiler not found"
      return false
    end
    
    # Generate parser
    puts "    Generating parser..."
    generate_status = Process.run("tree-sitter", ["generate"], 
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    ).success?
    
    unless generate_status
      puts "    ✗ Failed to generate parser"
      return false
    end
    
    # Build grammar
    puts "    Building grammar..."
    build_status = Process.run("tree-sitter", ["build"], 
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    ).success?
    
    unless build_status
      puts "    ✗ Failed to build grammar"
      return false
    end
    
    # Rename library if needed
    ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
    source_lib = "#{language}.#{ext}"
    lib_name = "libtree-sitter-#{language}.#{ext}"
    
    if File.exists?(source_lib) && !File.exists?(lib_name)
      File.rename(source_lib, lib_name)
    end
    
    # Verify library exists
    if File.exists?(lib_name)
      puts "    ✓ Library created: #{lib_name}"
      return true
    else
      puts "    ✗ Library not created"
      return false
    end
  end
rescue ex
  puts "    ✗ Error: #{ex.message}"
  false
end

def main
  puts "Downloading and compiling required grammars..."
  puts "Vendor directory: #{VENDOR_DIR}"
  puts ""
  
  success_count = 0
  fail_count = 0
  
  REQUIRED_LANGUAGES.each do |language|
    package = PACKAGE_MAP[language]
    if package
      if download_and_compile(language, package)
        success_count += 1
      else
        fail_count += 1
      end
    else
      puts "✗ No package mapping for #{language}"
      fail_count += 1
    end
    puts ""
  end
  
  puts "Summary:"
  puts "  Success: #{success_count}/#{REQUIRED_LANGUAGES.size}"
  puts "  Failed: #{fail_count}/#{REQUIRED_LANGUAGES.size}"
  
  if fail_count > 0
    puts "\nWarning: Some grammars failed to compile!"
    puts "The static binary may not include all required parsers."
    exit 1
  else
    puts "\n✓ All grammars successfully downloaded and compiled!"
  end
end

main