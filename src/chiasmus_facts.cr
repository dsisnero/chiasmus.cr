#!/usr/bin/env crystal
# CLI for tree-sitter-based code-graph FACT extraction.
#
# Emits layer-A Prolog facts (defines/5, calls/2, imports/3, exports/2,
# contains/2, entry_point/1 + derived rules) for any language we have a grammar
# for. This is the structural/relationship layer used to plan a port and verify
# completeness. See plans/parity_skills.md.
#
# Usage: chiasmus-facts --language LANG --dir DIR [options]
#   --language LANG        Language to analyze (default: crystal)
#   --dir DIR              Source directory to scan (default: .)
#   --entry-point NAME     Entry point for dead-code/reachability (repeatable)
#   --insights             Also emit community/2, cohesion/2, hub/2, bridge/2
#   --help, -h             Show this help
#
# Examples:
#   chiasmus-facts --language typescript --dir vendor/chiasmus/src > vendor.pl
#   chiasmus-facts --language crystal    --dir src                 > port.pl

require "option_parser"
require "./chiasmus/discovery"
require "./chiasmus/graph/analyses"

module Chiasmus
  module FactsCLI
    extend self

    LANGUAGE_EXTENSIONS = {
      "python"     => [".py"],
      "ruby"       => [".rb"],
      "java"       => [".java"],
      "go"         => [".go"],
      "rust"       => [".rs"],
      "scala"      => [".scala"],
      "crystal"    => [".cr"],
      "javascript" => [".js"],
      "typescript" => [".ts"],
      "tsx"        => [".tsx"],
      "c"          => [".c", ".h"],
      "cpp"        => [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"],
      "csharp"     => [".cs"],
      "bash"       => [".sh"],
      "dart"       => [".dart"],
      "kotlin"     => [".kt", ".kts"],
      "perl"       => [".pl", ".pm"],
      "php"        => [".php"],
      "proto"      => [".proto"],
    }

    def run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
      language = "crystal"
      dir = "."
      entry_points = [] of String
      insights = false
      help_requested = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: chiasmus-facts --language LANG --dir DIR [options]"
        opts.on("--language LANG", "Language to analyze (default: crystal)") { |v| language = v }
        opts.on("--dir DIR", "Source directory to scan (default: .)") { |v| dir = v }
        opts.on("--entry-point NAME", "Entry point for reachability/dead-code (repeatable)") { |v| entry_points << v }
        opts.on("--insights", "Also emit community/2, cohesion/2, hub/2, bridge/2 facts") { insights = true }
        opts.on("--help", "Show this help") { help_requested = true }
        opts.on("-h", "Show this help") { help_requested = true }
      end

      begin
        parser.parse(args)
      rescue ex
        error.puts ex.message
        error.puts parser
        return 1
      end

      if help_requested
        output.puts parser
        return 0
      end

      register_grammar_directories(dir)

      files = scan_files(language, dir)
      if files.empty?
        error.puts "No #{language} files found in #{dir}"
        return 1
      end

      request = Graph::AnalysisRequest.new(
        analysis: Graph::AnalysisType::Facts,
        entry_points: entry_points.empty? ? nil : entry_points,
        include_insights: insights,
      )

      result = Graph::Analyses.run_analysis_async(files, request).receive

      output.puts "% chiasmus-facts language=#{language} dir=#{dir} files=#{files.size}"
      output.puts result.result.as(String)
      0
    rescue ex
      error.puts ex.message || ex.class.name
      1
    end

    private def register_grammar_directories(scan_dir : String) : Nil
      grammar_directories(scan_dir).each do |path|
        Discovery.register_grammar_directory(path)
      end
    end

    private def grammar_directories(scan_dir : String) : Array(String)
      dirs = [] of String

      env_dir = ENV["CHIASMUS_GRAMMAR_DIR"]?
      dirs << env_dir if env_dir && Dir.exists?(env_dir)

      bundled_dirs.each do |path|
        dirs << path if Dir.exists?(path)
      end

      vendor_dir = File.join(scan_dir, "vendor", "grammars")
      dirs << vendor_dir if Dir.exists?(vendor_dir)

      repo_vendor = File.join(".", "vendor", "grammars")
      dirs << repo_vendor if Dir.exists?(repo_vendor)

      dirs.uniq
    end

    private def bundled_dirs : Array(String)
      executable = File.expand_path(PROGRAM_NAME)
      executable_dir = File.dirname(executable)

      [
        File.join(executable_dir, "grammars"),
        File.join(executable_dir, "..", "grammars"),
      ].map { |path| File.expand_path(path) }
    end

    private def scan_files(language : String, dir : String) : Array(String)
      extensions = LANGUAGE_EXTENSIONS[language]? || [".#{language}"]

      files = [] of String
      Dir.glob(File.join(dir, "**", "*")).sort!.each do |path|
        next unless File.file?(path)
        next unless extensions.any? { |ext| path.ends_with?(ext) }
        next if path.split('/').any?(&.starts_with?("._"))
        files << path
      end
      files
    end
  end
end

exit Chiasmus::FactsCLI.run(ARGV)
