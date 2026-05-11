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

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "method"
          node ? qualify_method(node, source, name) : name
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

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        @delegate.post_filter(kind, name, node, source)
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end

      def queries : Hash(String, String)
        @delegate.queries
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        @delegate.post_filter(kind, name, node, source)
      end
    end
  end
end
