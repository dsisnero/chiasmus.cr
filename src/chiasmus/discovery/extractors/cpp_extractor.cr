require "../extractor"

module Chiasmus
  module Discovery
    struct CppExtractor < QueryExtractor
      def language : String
        "cpp"
      end

      def extensions : Array(String)
        [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"]
      end

      def grammar_language : String
        "cpp"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (class_specifier name: (type_identifier) @name) @def
            (struct_specifier name: (type_identifier) @name) @def
          QUERY
          "function"  => "(function_definition declarator: (function_declarator declarator: (identifier) @name)) @def",
          "interface" => "(class_specifier name: (type_identifier) @name body: (field_declaration_list)) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.namespace" => "(namespace_definition name: (namespace_identifier) @name)",
          "field"                => <<-QUERY,
            (class_specifier body: (field_declaration_list (_) @field))
            (struct_specifier body: (field_declaration_list (_) @field))
          QUERY
        }
      end
    end
  end
end
