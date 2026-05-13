require "../extractor"

module Chiasmus
  module Discovery
    struct JavaScriptExtractor < QueryExtractor
      def language : String
        "javascript"
      end

      def extensions : Array(String)
        [".js", ".mjs", ".cjs"]
      end

      def grammar_language : String
        "javascript"
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_declaration name: (identifier) @name) @def",
          "function" => <<-QUERY,
            (function_declaration name: (identifier) @name) @def
            (variable_declarator name: (identifier) @name value: (arrow_function) @def)
          QUERY
          "method" => "(method_definition name: (property_identifier) @name) @def",
          "const"  => "(lexical_declaration (variable_declarator name: (identifier) @name) @def)",
          "test"   => <<-QUERY,
            (expression_statement
              (call_expression
                function: (identifier) @meta_func
                arguments: (arguments (string (string_fragment) @name))) @def)
          QUERY
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.constructor" => "(method_definition name: (property_identifier) @name (#eq? @name \"constructor\"))",
          "definition.import"      => <<-QUERY,
            (import_statement source: (string (string_fragment) @name))
            (import_statement (import_clause (named_imports (import_specifier name: (identifier) @name))))
          QUERY
          "reference.call"     => "(call_expression function: (identifier) @name)",
          "reference.call_sel" => "(call_expression function: (member_expression property: (property_identifier) @name object: (identifier) @parent))",
          "reference.class"    => "(new_expression constructor: (identifier) @name)",
          "field"              => "(class_body (field_definition property: (property_identifier) @name))",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "method"
          node ? qualify_method(node, source, name) : name
        when "definition.constructor"
          name == "constructor" ? name : nil
        when "field"
          name
        else name
        end
      end
    end

    struct TSXExtractor < QueryExtractor
      @delegate : TypeScriptExtractor

      def initialize
        @delegate = TypeScriptExtractor.new
      end

      def language : String
        "tsx"
      end

      def extensions : Array(String)
        [".tsx"]
      end

      def grammar_language : String
        "tsx"
      end

      def queries : Hash(String, String)
        @delegate.queries
      end

      def predicate_queries : Hash(String, String)
        @delegate.predicate_queries
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        @delegate.post_filter(kind, name, node, source)
      end
    end
  end
end
