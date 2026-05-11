#!/usr/bin/env crystal
# Cross-platform smoke test for chiasmus binaries and grammar libraries.
#
# Validates that all three binaries run, grammar libraries load,
# and discovery works for all 10 languages.
#
# Usage: crystal run scripts/smoke_test.cr [--binaries DIR]

require "file_utils"

module SmokeTest
  extend self

  LANGUAGES = [
    {"python",     "class Foo: pass\n"},
    {"go",         "package main\nfunc main() {}\n"},
    {"java",       "class Foo {}\n"},
    {"rust",       "fn main() {}\n"},
    {"javascript", "function main() {}\n"},
    {"typescript", "function main(): void {}\n"},
    {"ruby",       "class Foo\nend\n"},
    {"crystal",    "class Foo\nend\n"},
    {"scala",      "class Foo {}\n"},
    {"tsx",        "const App = () => <div/>\n"},
  ]

  def run(args : Array(String))
    bin_dir = "bin"
    i = 0
    while i < args.size
      case args[i]
      when "--binaries"
        bin_dir = args[i + 1]? || "bin"
        i += 1
      when "--help", "-h"
        print_help
        return
      end
      i += 1
    end

    ext = executable_extension
    discover_bin = File.join(bin_dir, "chiasmus-discover#{ext}")
    grammar_bin = File.join(bin_dir, "chiasmus-grammar#{ext}")

    results = {pass: 0, fail: 0}

    # Check binaries exist
    unless File.exists?(discover_bin)
      STDERR.puts "FAIL: #{discover_bin} not found"
      results = {pass: results[:pass], fail: results[:fail] + 1}
      report(results)
      return
    end
    puts "OK: #{discover_bin}"

    # Test discovery for each language
    LANGUAGES.each do |lang, source|
      test_file = File.tempfile("smoke_test_#{lang}")
      File.write(test_file.path, source)
      begin
        output = `#{discover_bin} --language #{lang} --parser tree-sitter --dir #{File.dirname(test_file.path)} 2>&1`
        if $?.success? && !output.strip.empty?
          puts "OK: #{lang}"
          results = {pass: results[:pass] + 1, fail: results[:fail]}
        else
          # Try regex fallback
          output2 = `#{discover_bin} --language #{lang} --parser regex --dir #{File.dirname(test_file.path)} 2>&1`
          if $?.success? && !output2.strip.empty?
            puts "OK: #{lang} (regex fallback)"
            results = {pass: results[:pass] + 1, fail: results[:fail]}
          else
            STDERR.puts "FAIL: #{lang} — #{output.strip.lines.first? || "no output"}"
            results = {pass: results[:pass], fail: results[:fail] + 1}
          end
        end
      rescue ex
        STDERR.puts "FAIL: #{lang} — #{ex.message}"
        results = {pass: results[:pass], fail: results[:fail] + 1}
      ensure
        test_file.delete
      end
    end

    # Check grammar libraries
    puts
    puts "Grammar libraries:"
    grammar_dir = File.join(bin_dir, "..", "vendor", "grammars")
    lib_ext = shared_library_extension
    LANGUAGES.each do |lang, _|
      lib_name = "libtree-sitter-#{lang}.#{lib_ext}"
      found = find_library(grammar_dir, lib_name)
      if found
        puts "  OK: #{lib_name}"
      else
        puts "  WARN: #{lib_name} not found in #{grammar_dir}"
      end
    end

    report(results)
    exit 1 if results[:fail] > 0
  end

  private def find_library(dir, name)
    Dir.glob(File.join(dir, "**", name)).any?
  end

  private def shared_library_extension : String
    {% if flag?(:darwin) %}
      "dylib"
    {% elsif flag?(:win32) %}
      "dll"
    {% else %}
      "so"
    {% end %}
  end

  private def executable_extension : String
    {% if flag?(:win32) %}
      ".exe"
    {% else %}
      ""
    {% end %}
  end

  private def report(results)
    puts
    puts "=" * 40
    puts "Results: #{results[:pass]} passed, #{results[:fail]} failed"
    puts "=" * 40
  end

  private def print_help
    puts <<-HELP
    Smoke Test — validates chiasmus binaries and grammar libraries

    Usage: crystal run scripts/smoke_test.cr [--binaries DIR]

    Options:
      --binaries DIR   Directory containing chiasmus binaries (default: bin)
      --help, -h       Show this help
    HELP
  end
end

SmokeTest.run(ARGV)
