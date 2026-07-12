require "option_parser"
require "./discovery"
require "./graph/analyses"
require "./graph/cache"
require "./index/fast_find"

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
      cache_dir = ENV["CHIASMUS_FACTS_CACHE_DIR"]? || ENV["CHIASMUS_CACHE_DIR"]?
      repo_key = ENV["CHIASMUS_FACTS_REPO_KEY"]?
      cache_max_bytes = ENV["CHIASMUS_CACHE_MAX_PER_REPO"]?.try(&.to_i32?)

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: chiasmus-facts --language LANG --dir DIR [options]"
        opts.on("--language LANG", "Language to analyze (default: crystal)") { |v| language = v }
        opts.on("--dir DIR", "Source directory to scan (default: .)") { |v| dir = v }
        opts.on("--entry-point NAME", "Entry point for reachability/dead-code (repeatable)") { |v| entry_points << v }
        opts.on("--insights", "Also emit community/2, cohesion/2, hub/2, bridge/2 facts") { insights = true }
        opts.on("--cache-dir DIR", "Enable persistent per-file extraction cache in DIR") { |v| cache_dir = v }
        opts.on("--repo-key KEY", "Override cache repo key (defaults to current working directory hash)") { |v| repo_key = v }
        opts.on("--cache-max-bytes BYTES", "Maximum bytes to retain in the cache repo") { |v| cache_max_bytes = v.to_i32 }
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

      analysis_result = Graph::Analyses.run_analysis(
        files,
        request,
        cache_dir: cache_dir,
        repo_key: repo_key,
        max_bytes: cache_max_bytes
      )
      Graph::GraphCache.flush_async_writes if cache_dir

      output.puts "% chiasmus-facts language=#{language} dir=#{dir} files=#{files.size}"
      output.puts analysis_result.result.as(String)
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

      config = FastFind::Config.new
      config.ignore_hidden = true
      config.follow_symlinks = false
      config.max_depth = 50
      walker = FastFind::Walker.new([dir], config)
      queue = walker.walk
      loop do
        entry = queue.receive?
        break if entry.nil?
        next unless entry.file?
        path = entry.path.to_s
        next if path.split('/').any?(&.starts_with?("._"))
        files << path if extensions.any? { |ext| path.ends_with?(ext) }
      end
      files
    end
  end
end
