#!/usr/bin/env crystal
# AST Explorer: parses a source file with tree-sitter and prints the AST structure.
# Useful for debugging query patterns and understanding node types.
#
# Usage: crystal run scripts/explore_ast.cr -- [options]
#   --grammar PATH   Path to grammar directory
#   --language NAME  Language name
#   --file PATH      Source file to parse
#   --source TEXT    Inline source code to parse
#   --depth N        Max tree depth (default: 5)
#   --node-types     Print only unique node type names
#   --fields         Print nodes with field names

require "tree_sitter"

module ASTExplorer
  extend self

  def run(args : Array(String))
    grammar_path = nil
    language = nil
    file_path = nil
    inline_source = nil
    max_depth = 5
    mode = "tree"

    i = 0
    while i < args.size
      case args[i]
      when "--grammar"; grammar_path = args[i + 1]?; i += 1
      when "--language"; language = args[i + 1]?; i += 1
      when "--file"; file_path = args[i + 1]?; i += 1
      when "--source"; inline_source = args[i + 1]?; i += 1
      when "--depth"; max_depth = args[i + 1]?.try(&.to_i) || 5; i += 1
      when "--node-types"; mode = "types"
      when "--fields"; mode = "fields"
      when "--help", "-h"; print_help; return
      end
      i += 1
    end

    unless grammar_path
      STDERR.puts "Error: --grammar is required"
      print_help
      exit 1
    end

    source = if inline_source
               inline_source
             elsif file_path
               File.read(file_path)
             else
               STDERR.puts "Error: --file or --source is required"
               exit 1
             end

    language ||= infer_language(grammar_path)
    lang = load_grammar(language, grammar_path)
    raise "Could not load grammar for #{language}" unless lang

    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(nil, source)

    case mode
    when "types"
      print_node_types(tree.root_node)
    when "fields"
      print_fields(tree.root_node, source, max_depth)
    else
      print_tree(tree.root_node, source, max_depth)
    end
  rescue ex
    STDERR.puts "Error: #{ex.message}"
    STDERR.puts ex.backtrace.join("\n")
    exit 1
  end

  private def infer_language(path : String) : String
    if path.includes?("tree-sitter-")
      path.split("tree-sitter-").last.split('/').first
    else
      File.basename(path)
    end
  end

  private def load_grammar(language : String, grammar_path : String) : TreeSitter::Language?
    ext = {% if flag?(:darwin) %} "dylib" {% elsif flag?(:win32) %} "dll" {% else %} "so" {% end %}
    lib_name = "libtree-sitter-#{language}"

    candidates = [
      File.join(grammar_path, "#{lib_name}.#{ext}"),
      File.join(grammar_path, "#{language}.#{ext}"),
      File.join(grammar_path, "parser.#{ext}"),
    ]

    # Search subdirectories for TypeScript-like grammars
    if Dir.exists?(grammar_path)
      Dir.children(grammar_path).each do |sub|
        sub_path = File.join(grammar_path, sub)
        next unless Dir.exists?(sub_path)
        candidates << File.join(sub_path, "#{lib_name}.#{ext}")
      end
    end

    lib_path = candidates.find { |p| File.exists?(p) }
    return nil unless lib_path

    handle = LibC.dlopen(lib_path, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
    return nil if handle.null?

    symbol_names = [
      "tree_sitter_#{language}",
      "tree_sitter_#{language.gsub('-', '_')}",
    ]

    ptr = nil
    symbol_names.each { |sym| ptr = LibC.dlsym(handle, sym); break if ptr }
    return nil unless ptr

    lang_ptr = Proc(LibTreeSitter::TSLanguage*).new(ptr, Pointer(Void).null).call
    TreeSitter::Language.new(language, lang_ptr)
  rescue
    nil
  end

  private def print_tree(node : TreeSitter::Node, source : String, max_depth : Int32, depth : Int32 = 0, prefix : String = "")
    return if depth > max_depth

    type = node.type
    named = node.named? ? "*" : " "
    start = node.start_point
    text_preview = node.text(source)[0..40]?.try(&.gsub('\n', ' ')) || ""

    puts "#{prefix}#{named}[#{type}] \"#{text_preview}\" @#{start.row}:#{start.column}"

    child_prefix = prefix + "  "
    count = node.child_count.to_i
    count.times do |i|
      child = node.child(i)
      field = node.field_name_for_child(i.to_u32)
      label = field ? "#{field}: " : ""
      print_tree(child, source, max_depth, depth + 1, child_prefix + label)
    end
  end

  private def print_node_types(node : TreeSitter::Node, seen = Set(String).new)
    return if seen.includes?(node.type)
    seen.add(node.type)
    named_mark = node.named? ? "named" : "anon"
    puts "#{node.type} (#{named_mark})"

    node.children.each { |child| print_node_types(child, seen) }
  end

  private def print_fields(node : TreeSitter::Node, source : String, max_depth : Int32, depth : Int32 = 0)
    return if depth > max_depth

    count = node.child_count.to_i
    fields = count.times.compact_map do |i|
      field = node.field_name_for_child(i.to_u32)
      field ? "#{field}:#{node.child(i).type}" : nil
    end

    if node.named? && !fields.empty?
      indent = "  " * depth
      puts "#{indent}#{node.type} fields=#{fields}"
    end

    count.times do |i|
      child = node.child(i)
      print_fields(child, source, max_depth, depth + 1)
    end
  end

  private def print_help
    puts <<-HELP
    AST Explorer

    Parses source code with tree-sitter and prints the AST structure.

    Usage: crystal run scripts/explore_ast.cr -- [options]

    Options:
      --grammar PATH   Path to grammar directory (required)
      --language NAME  Language name (inferred from path if omitted)
      --file PATH      Source file to parse
      --source TEXT    Inline source code
      --depth N        Max tree depth (default: 5)
      --node-types     Print only unique node type names
      --fields         Print node types with their field names
      --help, -h       Show this help

    Examples:
      crystal run scripts/explore_ast.cr -- \\
        --grammar vendor/grammars/tree-sitter-python \\
        --source "def foo(): pass"

      crystal run scripts/explore_ast.cr -- \\
        --grammar vendor/grammars/tree-sitter-go \\
        --file test.go --field-names
    HELP
  end
end

ASTExplorer.run(ARGV)
