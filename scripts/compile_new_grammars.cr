#!/usr/bin/env crystal
# Compile the 9 new codeium-parse grammar submodules.
require "file_utils"
require "process"

PROJECT_ROOT = File.expand_path("..", __DIR__)
VENDOR_DIR   = File.join(PROJECT_ROOT, "vendor/grammars")
TEMP_DIR     = File.join(PROJECT_ROOT, "tmp/grammars_new")

EXT = {% if flag?(:darwin) %} "dylib" {% elsif flag?(:win32) %} "dll" {% else %} "so" {% end %}

# Language → package name (directory in vendor/grammars/)
NEW_LANGUAGES = {
  "bash"   => "tree-sitter-bash",
  "c"      => "tree-sitter-c",
  "cpp"    => "tree-sitter-cpp",
  "csharp" => "tree-sitter-c-sharp",
  "dart"   => "tree-sitter-dart",
  "kotlin" => "tree-sitter-kotlin",
  "perl"   => "tree-sitter-perl",
  "php"    => "tree-sitter-php",
  "proto"  => "tree-sitter-proto",
}

Dir.mkdir_p(TEMP_DIR)

def compile_grammar(source_dir : String, language : String) : Bool
  return false unless Dir.exists?(source_dir)

  ts_cmd = if system("which tree-sitter > /dev/null 2>&1")
             "tree-sitter"
           elsif system("which npx > /dev/null 2>&1")
             "npx tree-sitter"
           else
             puts "  ✗ tree-sitter CLI not found"
             return false
           end

  Dir.cd(source_dir) do
    ts_parts = ts_cmd.split
    puts "    Generating parser..."
    unless Process.run(ts_parts[0], ts_parts[1..] + ["generate"],
             output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?
      puts "    ✗ Failed to generate"
      return false
    end

    puts "    Building..."
    unless Process.run(ts_parts[0], ts_parts[1..] + ["build"],
             output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      puts "    ✗ Failed to build"
      return false
    end

    lib_name = "libtree-sitter-#{language}.#{EXT}"
    candidates = ["#{language}.#{EXT}", "parser.#{EXT}"]
    source_lib = candidates.find { |c| File.exists?(c) }

    if source_lib && !File.exists?(lib_name)
      File.rename(source_lib, lib_name)
    end

    File.exists?(lib_name)
  end
rescue ex
  puts "    ✗ Error: #{ex.message}"
  false
end

success = 0
fail = 0

NEW_LANGUAGES.each do |language, package|
  submodule_dir = File.join(VENDOR_DIR, package)
  lib_name = "libtree-sitter-#{language}.#{EXT}"
  lib_path = File.join(submodule_dir, lib_name)

  puts "#{language} (#{package})"

  if File.exists?(lib_path)
    puts "  ✓ Already compiled"
    success += 1
    next
  end

  unless Dir.exists?(submodule_dir)
    puts "  ✗ Submodule directory not found: #{submodule_dir}"
    fail += 1
    next
  end

  target_dir = File.join(TEMP_DIR, package)
  FileUtils.rm_rf(target_dir) if Dir.exists?(target_dir)
  FileUtils.cp_r(submodule_dir, target_dir)

  if compile_grammar(target_dir, language)
    target_lib = File.join(target_dir, lib_name)
    if File.exists?(target_lib)
      FileUtils.cp(target_lib, lib_path)
      puts "  ✓ Compiled and installed"
      success += 1
    else
      puts "  ✗ Library not found after compile"
      fail += 1
    end
  else
    puts "  ✗ Compilation failed"
    fail += 1
  end
end

puts ""
puts "Done: #{success} succeeded, #{fail} failed"
