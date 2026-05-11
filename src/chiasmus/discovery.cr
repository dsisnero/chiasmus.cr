require "tree_sitter"
require "./discovery/grammar_loader"
require "./discovery/extractor"
require "./discovery/registry"
require "./discovery/pipeline"
require "./discovery/extractors/*"

# Tree-sitter Discovery module for TypeScript source code analysis.
#
# Uses tree-sitter queries to extract declarations (classes, interfaces,
# types, functions, methods, constants, tests) with stable IDs matching
# the parity inventory format: `{relative_path}::{kind}::{name}`.
#
# Supports a regex fallback mode when tree-sitter grammars are unavailable,
# and clearly reports which parser mode was used.
module Chiasmus
  module Discovery
    VERSION = "0.1.0"

    # Represents a discovered symbol.
    record Item,
      id : String,    # e.g. "src/app.ts::class::MyService"
      kind : String,  # class, interface, type, function, method, const, test
      scope : String, # source or test
      name : String,  # Simple name (may be qualified for methods)
      file : String   # Relative file path

    # Result of a discovery operation.
    record Result,
      items : Array(Item),
      parser_mode : String # "tree-sitter" or "regex"

    extend self

    # Delegated to GrammarLoader
    def register_grammar_directory(path : String) : Nil
      GrammarLoader.register_grammar_directory(path)
    end

    def tree_sitter_available?(language : String) : Bool
      GrammarLoader.tree_sitter_available?(language)
    end

    def find_grammar_library(language : String) : String?
      GrammarLoader.find_grammar_library(language)
    end

    def load_language(language : String) : TreeSitter::Language?
      GrammarLoader.load_language(language)
    end

    # Discover declarations in a single file.
    #
    # - `language`: target language (e.g. "typescript")
    # - `source`: source code content
    # - `file_path`: relative file path for ID generation
    # - `force_parser`: force a specific parser ("tree-sitter" or "regex")
    def discover_file(
      language : String,
      source : String,
      file_path : String,
      force_parser : String? = nil,
    ) : Result
      parser_mode = effective_parser_mode(language, force_parser)

      items = case parser_mode
              when "tree-sitter"
                discover_with_tree_sitter(language, source, file_path)
              else
                discover_with_regex(language, source, file_path)
              end

      Result.new(items: deduplicate(items), parser_mode: parser_mode)
    end

    # Discover declarations across multiple files.
    def discover_files(
      language : String,
      files : Array(Tuple(String, String)), # [(path, content), ...]
      force_parser : String? = nil,
    ) : Result
      all_items = [] of Item
      parser_mode = effective_parser_mode(language, force_parser)

      files.each do |path, content|
        file_result = discover_file(language, content, path, force_parser: force_parser)
        all_items.concat(file_result.items)
      end

      Result.new(items: deduplicate(all_items), parser_mode: parser_mode)
    end

    # -- Private implementation --

    private def effective_parser_mode(language : String, force_parser : String?) : String
      if force_parser
        case force_parser
        when "tree-sitter"
          return tree_sitter_available?(language) ? "tree-sitter" : "regex"
        when "regex"
          return "regex"
        else
          raise ArgumentError.new("Invalid parser mode: #{force_parser}")
        end
      end

      # Auto-detect
      tree_sitter_available?(language) ? "tree-sitter" : "regex"
    end

    private def deduplicate(items : Array(Item)) : Array(Item)
      seen = Set(String).new
      items.select { |item| seen.add?(item.id) }
    end

    # -- Tree-sitter discovery --

    private def discover_with_tree_sitter(language : String, source : String, file_path : String) : Array(Item)
      lang = load_language(language)
      return discover_with_regex(language, source, file_path) unless lang

      parser = TreeSitter::Parser.new(language: lang)
      tree = parser.parse(nil, source)
      extract_declarations(lang, tree.root_node, source, file_path)
    rescue ex
      # Fall back to regex on parse errors
      discover_with_regex(language, source, file_path)
    end

    private def extract_declarations(lang : TreeSitter::Language, root : TreeSitter::Node, source : String, file : String) : Array(Item)
      items = [] of Item

      extract_classes(lang, root, source, file, items)
      extract_interfaces(lang, root, source, file, items)
      extract_type_aliases(lang, root, source, file, items)
      extract_functions(lang, root, source, file, items)
      extract_arrow_functions(lang, root, source, file, items)
      extract_methods(lang, root, source, file, items)
      extract_constants(lang, root, source, file, items)
      extract_tests(lang, root, source, file, items)

      deduplicate(items)
    end

    private def extract_classes(lang, root, source, file, items)
      query_src = <<-QUERY
        (class_declaration name: (type_identifier) @cls) @def
        (abstract_class_declaration name: (type_identifier) @cls) @def
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "cls"
        name = capture.node.text(source)
        items << Item.new(id: "#{file}::class::#{name}", kind: "class", scope: "source", name: name, file: file)
      end
    rescue ex
    end

    private def extract_interfaces(lang, root, source, file, items)
      query_src = <<-QUERY
        (interface_declaration name: (type_identifier) @iface) @def
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "iface"
        name = capture.node.text(source)
        items << Item.new(id: "#{file}::interface::#{name}", kind: "interface", scope: "source", name: name, file: file)
      end
    rescue ex
    end

    private def extract_type_aliases(lang, root, source, file, items)
      query_src = <<-QUERY
        (type_alias_declaration name: (type_identifier) @t) @def
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "t"
        name = capture.node.text(source)
        items << Item.new(id: "#{file}::type::#{name}", kind: "type", scope: "source", name: name, file: file)
      end
    rescue ex
    end

    private def extract_functions(lang, root, source, file, items)
      query_src = <<-QUERY
        (function_declaration name: (identifier) @fn) @def
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "fn"
        name = capture.node.text(source)
        items << Item.new(id: "#{file}::function::#{name}", kind: "function", scope: "source", name: name, file: file)
      end
    rescue ex
    end

    private def extract_arrow_functions(lang, root, source, file, items)
      query_src = <<-QUERY
        (variable_declarator name: (identifier) @fn value: (arrow_function) @def)
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "fn"
        name = capture.node.text(source)
        items << Item.new(id: "#{file}::function::#{name}", kind: "function", scope: "source", name: name, file: file)
      end
    rescue ex
    end

    private def extract_methods(lang, root, source, file, items)
      query_src = <<-QUERY
        (method_definition name: (property_identifier) @m) @def
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "m"
        name = capture.node.text(source)
        class_name = find_enclosing_class(capture.node, source)
        full_name = class_name ? "#{class_name}.#{name}" : name
        items << Item.new(id: "#{file}::method::#{full_name}", kind: "method", scope: "source", name: full_name, file: file)
      end
    rescue ex
    end

    private def extract_constants(lang, root, source, file, items)
      query_src = <<-QUERY
        (lexical_declaration (variable_declarator name: (identifier) @c) @def)
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root) do |capture|
        next unless capture.rule == "c"
        name = capture.node.text(source)
        if name =~ /^[A-Z][A-Z0-9_]*$/
          items << Item.new(id: "#{file}::const::#{name}", kind: "const", scope: "source", name: name, file: file)
        end
      end
    rescue ex
    end

    private def extract_tests(lang, root, source, file, items)
      query_src = <<-QUERY
        (expression_statement
          (call_expression
            function: (identifier) @test_func
            arguments: (arguments (string (string_fragment) @test_name))) @def)
      QUERY
      query = TreeSitter::Query.new(lang, query_src)
      cursor = TreeSitter::QueryCursor.new(query)
      cursor.exec(root)
      while match = cursor.next_match
        func_name = nil
        test_name = nil
        match.captures.each do |cap|
          func_name = cap.node.text(source) if cap.rule == "test_func"
          test_name = cap.node.text(source) if cap.rule == "test_name"
        end
        if func_name && test_name && ["describe", "it", "test"].includes?(func_name)
          items << Item.new(id: "#{file}::test::#{test_name}", kind: "test", scope: "test", name: test_name, file: file)
        end
      end
    rescue ex
    end

    private def find_enclosing_class(node : TreeSitter::Node, source : String) : String?
      current = node.parent
      while current
        case current.type
        when "class_declaration", "abstract_class_declaration"
          name_node = current.child_by_field_name("name")
          return name_node.try(&.text(source))
        when "class_body"
          current = current.parent
          next
        end
        current = current.parent
      end
      nil
    end

    # -- Regex fallback discovery --

    private def discover_with_regex(language : String, source : String, file_path : String) : Array(Item)
      case language
      when "typescript", "javascript", "tsx"
        extract_typescript_regex(source, file_path)
      else
        [] of Item
      end
    end

    private def extract_typescript_regex(content : String, file : String) : Array(Item)
      items = [] of Item

      content.each_line do |line|
        stripped = line.strip

        # Strip export keyword
        stripped = stripped.gsub(/^export\s+/, "")

        # Class declarations
        if stripped =~ /^(abstract\s+)?class\s+([A-Z][A-Za-z0-9_$]*)/
          m = $2
          items << Item.new(id: "#{file}::class::#{m}", kind: "class", scope: "source", name: m, file: file)
        end

        # Interface declarations
        if stripped =~ /^interface\s+([A-Z][A-Za-z0-9_$]*)/
          m = $1
          items << Item.new(id: "#{file}::interface::#{m}", kind: "interface", scope: "source", name: m, file: file)
        end

        # Type alias declarations
        if stripped =~ /^type\s+([A-Z][A-Za-z0-9_$]*)\s*=/
          m = $1
          items << Item.new(id: "#{file}::type::#{m}", kind: "type", scope: "source", name: m, file: file)
        end

        # Function declarations
        if stripped =~ /^(async\s+)?function\s+([a-z_][A-Za-z0-9_$]*)/
          m = $2
          items << Item.new(id: "#{file}::function::#{m}", kind: "function", scope: "source", name: m, file: file)
        end

        # Arrow functions (const/let/var name = (...) => ...)
        if stripped =~ /^(const|let|var)\s+([a-z_][A-Za-z0-9_$]*)\s*=\s*(async\s+)?\(/
          m = $2
          items << Item.new(id: "#{file}::function::#{m}", kind: "function", scope: "source", name: m, file: file)
        end

        # Uppercase constants
        if stripped =~ /^(const|let|var)\s+([A-Z][A-Z0-9_$]*)\s*=/
          m = $2
          items << Item.new(id: "#{file}::const::#{m}", kind: "const", scope: "source", name: m, file: file)
        end

        # Test declarations
        if stripped =~ /^(describe|it|test)\s*\(\s*["'](.+?)["']/
          m = $2
          items << Item.new(id: "#{file}::test::#{m}", kind: "test", scope: "test", name: m, file: file)
        end
      end

      items
    end
  end
end
