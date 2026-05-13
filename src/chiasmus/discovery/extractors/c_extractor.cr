require "../extractor"

module Chiasmus
  module Discovery
    struct CExtractor < QueryExtractor
      def language : String
        "c"
      end

      def extensions : Array(String)
        [".c", ".h"]
      end

      def grammar_language : String
        "c"
      end

      def queries : Hash(String, String)
        {
          "function" => "(function_definition declarator: (function_declarator declarator: (identifier) @name)) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.import" => "(preproc_include path: (_) @name)",
        }
      end
    end
  end
end
