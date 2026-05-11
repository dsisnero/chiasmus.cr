require "../extractor"

module Chiasmus
  module Discovery
    # TypeScript/JavaScript extractor using tree-sitter queries.
    struct TypeScriptExtractor < QueryExtractor
      def language : String
        "typescript"
      end

      def extensions : Array(String)
        [".ts", ".tsx"]
      end

      def grammar_language : String
        "typescript"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (class_declaration name: (type_identifier) @name) @def
            (abstract_class_declaration name: (type_identifier) @name) @def
          QUERY
          "interface" => "(interface_declaration name: (type_identifier) @name) @def",
          "type"      => "(type_alias_declaration name: (type_identifier) @name) @def",
          "function"  => <<-QUERY,
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

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "method"
          node ? qualify_method(node, source, name) : name
        when "test"
          # Test queries use multi-capture - handled in QueryExtractor
          name
        else
          name
        end
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end
    end

    # Test extractor used in specs — composition over inheritance
    struct TestExtractor < QueryExtractor
      @delegate : TypeScriptExtractor

      def initialize
        @delegate = TypeScriptExtractor.new
      end

      def language : String
        @delegate.language
      end

      def extensions : Array(String)
        [".ts", ".tsx", ".test.ts"]
      end

      def grammar_language : String
        @delegate.grammar_language
      end

      def queries : Hash(String, String)
        @delegate.queries
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        @delegate.post_filter(kind, name, node, source)
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end
    end
  end
end
