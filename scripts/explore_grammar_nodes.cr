#!/usr/bin/env crystal
# Grammar node-type explorer: reads tree-sitter node-types.json
# and generates query pattern templates for each language.
#
# Usage: crystal run scripts/explore_grammar_nodes.cr -- [options]
#   --grammar PATH   Path to grammar directory (containing src/node-types.json)
#   --language NAME  Language name for output
#   --json           Output raw JSON node types
#   --queries        Output suggested query patterns
#   --all            Output everything (default)

require "json"
require "file_utils"

module GrammarExplorer
  record FieldInfo, name : String, types : Array(String), required : Bool

  record NodeType, type : String, named : Bool, subtypes : Array(String), fields : Hash(String, FieldInfo), children_types : Array(String)

  extend self

  def run(args : Array(String))
    grammar_path = nil
    language = nil
    mode = "all"

    i = 0
    while i < args.size
      case args[i]
      when "--grammar"; grammar_path = args[i + 1]?; i += 1
      when "--language"; language = args[i + 1]?; i += 1
      when "--json"; mode = "json"
      when "--queries"; mode = "queries"
      when "--all"; mode = "all"
      when "--help", "-h"; print_help; return
      end
      i += 1
    end

    unless grammar_path && Dir.exists?(grammar_path)
      STDERR.puts "Usage: crystal run scripts/explore_grammar_nodes.cr -- --grammar PATH [--language NAME]"
      STDERR.puts "Example: crystal run scripts/explore_grammar_nodes.cr -- --grammar vendor/grammars/tree-sitter-python --language python"
      exit 1
    end

    language ||= infer_language(grammar_path)
    node_types = parse_node_types(grammar_path)

    case mode
    when "json"
      json_out = JSON.build do |json|
        json.array do
          node_types.each do |nt|
            json.object do
              json.field "type", nt.type
              json.field "named", nt.named
              json.field "subtypes", nt.subtypes
              json.field "field_names", nt.fields.keys
              json.field "children_types", nt.children_types
            end
          end
        end
      end
      puts json_out
    when "queries"
      generate_queries(node_types, language)
    else
      print_summary(node_types, language)
      puts
      generate_queries(node_types, language)
    end
  end

  private def infer_language(path : String) : String
    if path.includes?("tree-sitter-")
      path.split("tree-sitter-").last.split('/').first
    else
      File.basename(path)
    end
  end

  private def parse_node_types(grammar_path : String) : Array(NodeType)
    json_path = File.join(grammar_path, "src", "node-types.json")
    unless File.exists?(json_path)
      # Try subdirectory (e.g. tree-sitter-typescript/typescript/)
      Dir.children(grammar_path).each do |sub|
        sub_path = File.join(grammar_path, sub)
        candidate = File.join(sub_path, "src", "node-types.json")
        if File.exists?(candidate)
          json_path = candidate
          break
        end
      end
    end

    raise "node-types.json not found in #{grammar_path}" unless File.exists?(json_path)

    raw = Array(Hash(String, JSON::Any)).from_json(File.read(json_path))
    raw.map do |entry|
      type = entry["type"].to_s
      named = entry["named"].as_bool
      subtypes = entry["subtypes"]?.try(&.as_a.map(&.as_h["type"].to_s)) || [] of String

      fields = {} of String => FieldInfo
      entry["fields"]?.try &.as_h.each do |name, info_h|
        types = info_h.as_h["types"]?.try(&.as_a.map(&.as_h["type"].to_s)) || [] of String
        required = info_h.as_h["required"]?.try(&.as_bool) || false
        fields[name.to_s] = FieldInfo.new(name: name.to_s, types: types, required: required)
      end

      children = entry["children"]?.try &.as_h["types"]?.try(&.as_a.map(&.as_h["type"].to_s)) || [] of String

      NodeType.new(type: type, named: named, subtypes: subtypes, fields: fields, children_types: children)
    end
  end

  private def print_summary(node_types : Array(NodeType), language : String)
    named = node_types.select(&.named)
    puts "# Grammar: #{language}"
    puts "# Total node types: #{node_types.size} (#{named.size} named)"
    puts
    puts "## Definition nodes (potential class/interface/function/method targets):"

    definition_patterns = [
      /class/, /interface/, /struct/, /enum/, /trait/, /module/,
      /function/, /method/, /defn/, /def_/,
      /declaration/, /definition/, /_item/, /_def$/,
    ]

    named.each do |nt|
      if definition_patterns.any? { |re| nt.type =~ re }
        fields_str = nt.fields.empty? ? "" : " fields: [#{nt.fields.keys.join(", ")}]"
        subtypes_str = nt.subtypes.empty? ? "" : " subtypes: [#{nt.subtypes.join(", ")}]"
        puts "  #{nt.type}#{fields_str}#{subtypes_str}"
      end
    end

    puts
    puts "## Field names used across all node types:"
    all_fields = Hash(String, Int32).new(0)
    named.each { |nt| nt.fields.each_key { |k| all_fields[k] += 1 } }
    all_fields.to_a.sort_by { |_, c| -c }.each { |name, count| puts "  #{name}: #{count} types" }
  end

  private def generate_queries(node_types : Array(NodeType), language : String)
    named = node_types.select(&.named)
    lang = language

    puts "# Suggested tree-sitter query patterns for #{lang}"
    puts

    # Class-like
    class_nodes = named.select { |nt| nt.type =~ /(class|struct|enum|object)_(declaration|definition|def|item)$/ && nt.fields.has_key?("name") }
    class_nodes += named.select { |nt| nt.type =~ /record_declaration|abstract_class/ && nt.fields.has_key?("name") }
    unless class_nodes.empty?
      puts "# --- Classes ---"
      class_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "identifier" : "identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.class"
      end
      puts
    end

    # Interface/trait/module-like
    interface_nodes = named.select { |nt| nt.type =~ /(interface|trait|module)_(declaration|definition|def)$/ && nt.fields.has_key?("name") }
    unless interface_nodes.empty?
      puts "# --- Interfaces / Traits / Modules ---"
      interface_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "identifier" : "identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.interface"
      end
      puts
    end

    # Type aliases
    type_nodes = named.select { |nt| nt.type =~ /type_(alias|definition|item)$/ && nt.fields.has_key?("name") }
    type_nodes += named.select { |nt| nt.type == "type_declaration" && nt.fields.has_key?("name") }
    unless type_nodes.empty?
      puts "# --- Type aliases ---"
      type_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "type_identifier" : "type_identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.type"
      end
      puts
    end

    # Functions
    func_nodes = named.select { |nt| nt.type =~ /function_(declaration|definition|item)$/ && nt.fields.has_key?("name") }
    func_nodes += named.select { |nt| nt.type =~ /^function$/ && nt.fields.has_key?("name") }
    unless func_nodes.empty?
      puts "# --- Functions ---"
      func_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "identifier" : "identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.function"
      end
      puts
    end

    # Methods (alternative name for function-in-class)
    method_nodes = named.select { |nt| nt.type =~ /method_(declaration|definition|def)$/ && nt.fields.has_key?("name") }
    unless method_nodes.empty?
      puts "# --- Methods ---"
      method_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "identifier" : "identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.method"
      end
      puts
    end

    # Constant declarations
    const_nodes = named.select { |nt| nt.type =~ /(const|val|var)_(declaration|definition|item|spec)$/ && nt.fields.has_key?("name") }
    unless const_nodes.empty?
      puts "# --- Constants / Variables ---"
      const_nodes.each do |nt|
        name_field = nt.fields["name"]
        capture_type = name_field ? name_field.types.first? || "identifier" : "identifier"
        puts "(#{nt.type} name: (#{capture_type}) @name) @def.const"
      end
      puts
    end

    # Call expressions (for test detection)
    call_nodes = named.select { |nt| nt.type =~ /call_expression|call$/ && nt.fields.has_key?("function") }
    unless call_nodes.empty?
      puts "# --- Call expressions (test detection) ---"
      call_nodes.each do |nt|
        func_field = nt.fields["function"]
        if func_field
          capture_type = func_field.types.first? || "identifier"
          puts "(#{nt.type} function: (#{capture_type}) @test_func) @def.test"
        end
      end
      puts
    end

    puts "# Usage:"
    puts "#   - Copy patterns into your extractor class"
    puts "#   - Add post_filter for constant (UPPERCASE), method (enclosing class), test (func name)"
    puts "#   - Use `@name` capture for the symbol name"
  end

  private def print_help
    puts <<-HELP
    Grammar Node-Type Explorer

    Reads tree-sitter grammar's node-types.json and generates query pattern templates.

    Usage: crystal run scripts/explore_grammar_nodes.cr -- [options]

    Options:
      --grammar PATH   Path to grammar directory (containing src/node-types.json)
      --language NAME  Language name for output labeling
      --json           Output raw JSON of parsed node types
      --queries        Output suggested tree-sitter query patterns
      --all            Output summary + queries (default)
      --help, -h       Show this help

    Examples:
      crystal run scripts/explore_grammar_nodes.cr -- \\
        --grammar vendor/grammars/tree-sitter-python --language python

      crystal run scripts/explore_grammar_nodes.cr -- \\
        --grammar vendor/grammars/tree-sitter-rust --queries
    HELP
  end
end

GrammarExplorer.run(ARGV)
