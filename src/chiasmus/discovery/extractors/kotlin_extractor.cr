require "../extractor"

module Chiasmus
  module Discovery
    struct KotlinExtractor < QueryExtractor
      def language : String
        "kotlin"
      end

      def extensions : Array(String)
        [".kt", ".kts"]
      end

      def grammar_language : String
        "kotlin"
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_declaration (type_identifier) @name) @def",
          "function" => "(function_declaration (simple_identifier) @name) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.constructor" => "(secondary_constructor) @def",
          "definition.import"      => "(import_header (identifier) @name)",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        if kind == "definition.constructor"
          "constructor"
        else
          name
        end
      end
    end
  end
end
