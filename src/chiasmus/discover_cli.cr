require "./discovery"
require "./utils/bounded_work"

module Chiasmus
  module DiscoverCLI
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

    DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT

    @@before_scan_file_read_hook = nil.as((String -> Nil)?)
    @@before_scan_file_read_hook_mutex = Mutex.new
    @@scan_max_concurrent_for_test = nil.as(Int32?)
    @@scan_max_concurrent_for_test_mutex = Mutex.new

    def run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
      language, dir, force_parser = parse_args(args)
      return print_help(output) if language.nil?
      dir ||= "."

      register_grammar_directories(dir)

      files = scan_files(language, dir)
      return abort_no_files(language, dir, error) if files.empty?

      result = Chiasmus::Discovery.discover_files(language, files, force_parser: force_parser)
      output_result(result, output)
      0
    end

    def scan_files_for_test(language : String, dir : String) : Array(Tuple(String, String))
      scan_files(language, dir)
    end

    private def parse_args(args : Array(String)) : Tuple(String?, String?, String?)
      language = "typescript"
      dir = "."
      force_parser = nil

      i = 0
      while i < args.size
        case args[i]
        when "--language"
          language = args[i + 1]?
          i += 1
        when "--dir"
          dir = args[i + 1]? || "."
          i += 1
        when "--parser"
          force_parser = args[i + 1]?
          i += 1
        when "--help", "-h"
          return {nil, nil, nil}
        end
        i += 1
      end

      {language, dir, force_parser == "auto" ? nil : force_parser}
    end

    private def register_grammar_directories(scan_dir : String) : Nil
      grammar_directories(scan_dir).each do |path|
        Chiasmus::Discovery.register_grammar_directory(path)
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

    private def scan_files(language : String, dir : String) : Array(Tuple(String, String))
      extensions = LANGUAGE_EXTENSIONS[language]? || [".#{language}"]
      paths = Dir.glob(File.join(dir, "**", "*")).select do |path|
        File.file?(path) && extensions.any? { |ext| path.ends_with?(ext) }
      end

      Utils::BoundedWork.map_ordered_or_raise(paths, scan_max_concurrent) do |path|
        rel = path.lchop?(dir).try(&.lchop?('/')) || path
        run_before_scan_file_read_hook(path)
        {rel, File.read(path)}
      end
    end

    private def abort_no_files(language : String, dir : String, error : IO) : Int32
      error.puts "No #{language} files found in #{dir}"
      1
    end

    private def output_result(result, output : IO) : Nil
      output.puts "# source_id\tkind\tstatus\tcrystal_refs\tnotes"
      result.items.each do |item|
        output.puts "#{item.id}\t#{item.kind}\tported\t-\tparser=#{result.parser_mode}"
      end
    end

    private def print_help(output : IO) : Int32
      output.puts <<-HELP
      Tree-sitter Source Discovery CLI

      Usage: chiasmus_discover [options]

      Options:
        --language LANG    Language to discover (default: typescript)
        --dir DIR          Source directory to scan (default: .)
        --parser MODE      Parser mode: auto|tree-sitter|regex (default: auto)
        --help, -h         Show this help

      Output:
        TSV format compatible with parity inventory manifests.
        Includes parser mode in notes column.
        Grammar lookup order: CHIASMUS_GRAMMAR_DIR, bundled ./grammars, scan-dir grammars.
      HELP
      0
    end

    protected def run_before_scan_file_read_hook(path : String) : Nil
      hook = @@before_scan_file_read_hook_mutex.synchronize { @@before_scan_file_read_hook }
      hook.try(&.call(path))
    end

    private def scan_max_concurrent : Int32
      override = @@scan_max_concurrent_for_test_mutex.synchronize { @@scan_max_concurrent_for_test }
      Math.max(1, override || DEFAULT_MAX_CONCURRENT)
    end

    def set_before_scan_file_read_hook_for_test(&block : String ->) : Nil
      @@before_scan_file_read_hook_mutex.synchronize do
        @@before_scan_file_read_hook = block
      end
    end

    def clear_before_scan_file_read_hook_for_test : Nil
      @@before_scan_file_read_hook_mutex.synchronize do
        @@before_scan_file_read_hook = nil
      end
    end

    def scan_max_concurrent_for_test=(value : Int32) : Nil
      @@scan_max_concurrent_for_test_mutex.synchronize do
        @@scan_max_concurrent_for_test = value
      end
    end

    def clear_scan_max_concurrent_for_test : Nil
      @@scan_max_concurrent_for_test_mutex.synchronize do
        @@scan_max_concurrent_for_test = nil
      end
    end
  end
end
