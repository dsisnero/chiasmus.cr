require "../extractor"

module Chiasmus
  module Discovery
    struct CSharpExtractor < QueryExtractor
      def language : String
        "csharp"
      end

      def extensions : Array(String)
        [".cs"]
      end

      def grammar_language : String
        "csharp"
      end

      def queries : Hash(String, String)
        {
          "class"     => "(class_declaration name: (identifier) @name) @def",
          "interface" => "(interface_declaration name: (identifier) @name) @def",
          "method"    => "(method_declaration name: (identifier) @name) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.namespace" => <<-QUERY,
            (file_scoped_namespace_declaration name: (identifier) @name)
            (namespace_declaration name: (identifier) @name)
          QUERY
          "definition.class" => <<-QUERY,
            (struct_declaration name: (identifier) @name)
            (record_declaration name: (identifier) @name)
          QUERY
          "definition.enum"        => "(enum_declaration name: (identifier) @name)",
          "definition.constructor" => "(constructor_declaration name: (identifier) @name)",
          "definition.destructor"  => "(destructor_declaration name: (identifier) @name)",
        }
      end
    end
  end
end
