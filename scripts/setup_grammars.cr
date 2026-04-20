#!/usr/bin/env crystal

require "file_utils"
require "process"

# Required languages for static binary (with dependencies)
REQUIRED_LANGUAGES = {
  "javascript" => [] of String,
  "typescript" => ["javascript"],
  "tsx"        => ["javascript"],
  "python"     => [] of String,
  "java"       => [] of String,
  "go"         => [] of String,
  "rust"       => [] of String,
  "scala"      => [] of String,
  "ruby"       => [] of String,
  "crystal"    => [] of String,
}

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

# Main vendor directory (where the project expects them)
MAIN_VENDOR_DIR = File.expand_path("vendor/grammars", __DIR__)
# Temp directory for downloads
TEMP_DIR = File.expand_path("tmp/grammars", __DIR__)

Dir.mkdir_p(MAIN_VENDOR_DIR)
Dir.mkdir_p(TEMP_DIR)

def ensure_dependencies(language : String, dependencies : Array(String), compiled : Set(String)) : Bool
  dependencies.each do |dep|
    unless compiled.includes?(dep)
      puts "  ⚠ #{language} requires #{dep}, but it's not compiled yet"
      return false
    end
  end
  true
end

def download_and_compile(language : String, package : String, temp_dir : String) : Bool
  puts "Processing #{language} (#{package})..."
  
  target_dir = File.join(temp_dir, package)
  main_target_dir = File.join(MAIN_VENDOR_DIR, package)
  
  # Check if already exists in main vendor
  if Dir.exists?(main_target_dir)
    puts "  ✓ Already exists in main vendor"
    
    # Check if compiled library exists
    ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
    lib_name = "libtree-sitter-#{language}.#{ext}"
    lib_path = File.join(main_target_dir, lib_name)
    
    if File.exists?(lib_path)
      puts "  ✓ Compiled library exists"
      return true
    else
      puts "  ✗ No compiled library, will compile..."
    end
  end
  
  # Download if needed
  unless Dir.exists?(target_dir)
    puts "  Downloading from GitHub..."
    
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
  
  compile_success = false
  if language == "typescript"
    compile_subdir = File.join(target_dir, "typescript")
    compile_success = compile_grammar(compile_subdir, language)
  elsif language == "tsx"
    compile_subdir = File.join(target_dir, "tsx")
    compile_success = compile_grammar(compile_subdir, language)
  else
    compile_success = compile_grammar(target_dir, language)
  end
  
  if compile_success
    # Copy to main vendor directory
    puts "  Copying to main vendor directory..."
    FileUtils.rm_rf(main_target_dir) if Dir.exists?(main_target_dir)
    FileUtils.cp_r(target_dir, main_target_dir)
    puts "  ✓ Successfully compiled and installed #{language}"
    return true
  else
    puts "  ✗ Failed to compile #{language}"
    return false
  end
end

def compile_grammar(source_dir : String, language : String) : Bool
  return false unless Dir.exists?(source_dir)
  
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
      # Try with --log flag to see error
      Process.run("tree-sitter", ["generate", "--log"], 
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      )
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
      # Check what files exist
      Dir.children(".").select { |f| f.ends_with?(".#{ext}") }.each do |f|
        puts "    Found: #{f}"
      end
      return false
    end
  end
rescue ex
  puts "    ✗ Error: #{ex.message}"
  false
end

def check_existing_grammars : Set(String)
  compiled = Set(String).new
  
  REQUIRED_LANGUAGES.each_key do |language|
    package = PACKAGE_MAP[language]?
    next unless package
    
    target_dir = File.join(MAIN_VENDOR_DIR, package)
    next unless Dir.exists?(target_dir)
    
    ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
    lib_name = "libtree-sitter-#{language}.#{ext}"
    lib_path = File.join(target_dir, lib_name)
    
    # For TypeScript/TSX, check in subdirectories
    if language == "typescript"
      typescript_dir = File.join(target_dir, "typescript")
      lib_path = File.join(typescript_dir, lib_name) if Dir.exists?(typescript_dir)
    elsif language == "tsx"
      tsx_dir = File.join(target_dir, "tsx")
      lib_path = File.join(tsx_dir, lib_name) if Dir.exists?(tsx_dir)
    end
    
    if File.exists?(lib_path)
      compiled.add(language)
    end
  end
  
  compiled
end

def main
  puts "Setting up required grammars for static binary..."
  puts "Main vendor directory: #{MAIN_VENDOR_DIR}"
  puts "Temp directory: #{TEMP_DIR}"
  puts ""
  
  # Check what we already have
  compiled = check_existing_grammars
  puts "Already compiled: #{compiled.to_a.sort.join(", ")}" unless compiled.empty?
  puts ""
  
  success_count = 0
  fail_count = 0
  skipped_count = 0
  
  # Process languages in dependency order
  processed = Set(String).new
  max_attempts = REQUIRED_LANGUAGES.size * 2  # Allow multiple passes for dependencies
  
  max_attempts.times do |attempt|
    break if processed.size == REQUIRED_LANGUAGES.size
    
    REQUIRED_LANGUAGES.each do |language, deps|
      next if processed.includes?(language)
      next unless ensure_dependencies(language, deps, compiled)
      
      package = PACKAGE_MAP[language]?
      unless package
        puts "✗ No package mapping for #{language}"
        processed.add(language)
        fail_count += 1
        next
      end
      
      # Skip if already compiled
      if compiled.includes?(language)
        puts "✓ #{language} already compiled, skipping"
        processed.add(language)
        skipped_count += 1
        next
      end
      
      if download_and_compile(language, package, TEMP_DIR)
        compiled.add(language)
        processed.add(language)
        success_count += 1
      else
        processed.add(language)  # Mark as processed even if failed to avoid infinite loop
        fail_count += 1
      end
      
      puts ""
    end
  end
  
  puts "=" * 60
  puts "Summary:"
  puts "  Total required: #{REQUIRED_LANGUAGES.size}"
  puts "  Successfully compiled: #{success_count}"
  puts "  Already existed: #{skipped_count}"
  puts "  Failed: #{fail_count}"
  puts ""
  
  # List what we have
  puts "Compiled grammars:"
  REQUIRED_LANGUAGES.each_key do |language|
    status = compiled.includes?(language) ? "✓" : "✗"
    puts "  #{status} #{language}"
  end
  
  if fail_count > 0
    puts "\n⚠ Warning: Some grammars failed to compile!"
    puts "The static binary may not include all required parsers."
    exit 1
  else
    puts "\n✅ All required grammars are available!"
  end
end

main