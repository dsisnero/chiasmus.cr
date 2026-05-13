require "../extractor"

module Chiasmus
  module Discovery
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

      def predicate_queries : Hash(String, String)
        {
          "definition.module"      => "(internal_module name: (identifier) @name)",
          "definition.namespace"   => "(module name: (string (string_fragment) @name))",
          "definition.constructor" => "(method_definition name: (property_identifier) @name (#eq? @name \"constructor\"))",
          "definition.import"      => <<-QUERY,
            (import_statement source: (string (string_fragment) @name))
            (import_statement (import_clause (named_imports (import_specifier name: (identifier) @name))))
          QUERY
          "reference.call"     => "(call_expression function: (identifier) @name)",
          "reference.call_sel" => "(call_expression function: (member_expression property: (property_identifier) @name object: (identifier) @parent))",
          "reference.class"    => "(new_expression constructor: (identifier) @name)",
          "field"              => "(class_body (public_field_definition name: (property_identifier) @name))",
          "field_prop"         => <<-QUERY,
            (object_type (property_signature name: (property_identifier) @name))
            (interface_body (property_signature name: (property_identifier) @name))
          QUERY
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
        when "field", "field_prop"
          name
        when "test"
          name
        else
          name
        end
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end
    end

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

      def predicate_queries : Hash(String, String)
        @delegate.predicate_queries
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
