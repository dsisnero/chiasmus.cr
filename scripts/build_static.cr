#!/usr/bin/env crystal

require "file_utils"
require "process"

# Build script for creating a static binary with embedded grammars

def build_static_binary
  puts "Building static binary with embedded grammars..."
  
  # First, ensure all grammars are compiled
  puts "Checking grammar libraries..."
  
  required_grammars = [
    "ruby", "python", "java", "go", "rust", "scala", "javascript", "typescript", "tsx", "crystal"
  ]
  
  missing_grammars = [] of String
  vendor_dir = File.expand_path("vendor/grammars", __DIR__)
  
  required_grammars.each do |language|
    ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
    lib_name = "libtree-sitter-#{language}.#{ext}"
    
    # Check paths
    paths = [
      File.join(vendor_dir, "tree-sitter-#{language}", lib_name),
      File.join(vendor_dir, "tree-sitter-#{language}", language, lib_name), # For TypeScript/TSX
    ]
    
    found = paths.any? { |p| File.exists?(p) }
    
    unless found
      missing_grammars << language
      puts "  ✗ Missing: #{language}"
    else
      puts "  ✓ Found: #{language}"
    end
  end
  
  if missing_grammars.any?
    puts "\nError: Missing grammar libraries: #{missing_grammars.join(", ")}"
    puts "Run 'crystal run scripts/setup_grammars.cr' to download and compile missing grammars."
    exit 1
  end
  
  puts "\nAll grammar libraries found!"
  
  # Build the binary
  puts "\nBuilding binary..."
  
  build_args = [
    "build",
    "--release",
    "--static",  # Static linking
    "-o", "bin/chiasmus-static",
    "src/chiasmus.cr"
  ]
  
  puts "Running: crystal #{build_args.join(" ")}"
  
  success = Process.run("crystal", build_args, 
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit
  ).success?
  
  if success
    puts "\n✅ Successfully built static binary: bin/chiasmus-static"
    
    # Check binary size
    if File.exists?("bin/chiasmus-static")
      size = File.size("bin/chiasmus-static")
      puts "Binary size: #{size / 1024 / 1024} MB"
    end
    
    # Test the binary
    puts "\nTesting binary..."
    test_success = Process.run("bin/chiasmus-static", ["--help"], 
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    ).success?
    
    if test_success
      puts "✅ Binary runs successfully!"
    else
      puts "⚠ Binary may have issues running"
    end
  else
    puts "\n❌ Failed to build binary"
    exit 1
  end
end

def main
  puts "Chiasmus Static Binary Builder"
  puts "==============================="
  puts ""
  
  build_static_binary
end

main