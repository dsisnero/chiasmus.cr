#!/usr/bin/env crystal
# CLI for Tree-sitter-based source code discovery.
# Outputs declarations in TSV format matching parity inventory conventions.
#
# Usage: crystal run src/chiasmus_discover.cr -- [options]
#   --language LANG    Language to discover (e.g. "typescript")
#   --dir DIR          Source directory to scan
#   --parser MODE      Parser mode: auto|tree-sitter|regex (default: auto)
#   --tsv              Output TSV format (default)

require "./chiasmus/discovery"

module CLI
  extend self

  def run(args : Array(String))
    language, dir, force_parser = parse_args(args)
    return print_help if language.nil?
    dir ||= "."

    Chiasmus::Discovery.register_grammar_directory(File.join(dir, "vendor/grammars"))

    files = scan_files(language, dir)
    abort_no_files(language, dir) if files.empty?

    result = Chiasmus::Discovery.discover_files(language, files, force_parser: force_parser)
    output_result(result)
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

  private def scan_files(language : String, dir : String) : Array(Tuple(String, String))
    extensions = case language
                 when "typescript" then [".ts"]
                 when "javascript" then [".js"]
                 when "tsx"        then [".tsx"]
                 else                   [".#{language}"]
                 end

    files = [] of Tuple(String, String)
    Dir.glob(File.join(dir, "**", "*")).each do |path|
      next unless File.file?(path)
      next unless extensions.any? { |ext| path.ends_with?(ext) }
      rel = path.lchop?(dir).try(&.lchop?('/')) || path
      content = File.read(path)
      files << {rel, content}
    end
    files
  end

  private def abort_no_files(language, dir)
    STDERR.puts "No #{language} files found in #{dir}"
    exit 1
  end

  private def output_result(result)
    puts "# source_id\tkind\tstatus\tcrystal_refs\tnotes"
    result.items.each do |item|
      puts "#{item.id}\t#{item.kind}\tported\t-\tparser=#{result.parser_mode}"
    end
  end

  private def print_help
    puts <<-HELP
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
    HELP
  end
end

CLI.run(ARGV)
