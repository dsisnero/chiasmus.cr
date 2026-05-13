require "../extractor"

module Chiasmus
  module Discovery
    struct PhpExtractor < QueryExtractor
      def language : String
        "php"
      end

      def extensions : Array(String)
        [".php"]
      end

      def grammar_language : String
        "php"
      end

      def queries : Hash(String, String)
        {
          "class"     => "(class_declaration name: (name) @name) @def",
          "interface" => "(interface_declaration name: (name) @name) @def",
          "function"  => "(function_definition name: (name) @name) @def",
          "method"    => "(method_declaration name: (name) @name) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.namespace" => "(namespace_definition name: (namespace_name) @name)",
        }
      end
    end
  end
end
