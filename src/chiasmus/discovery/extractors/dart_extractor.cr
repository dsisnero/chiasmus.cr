require "../extractor"

module Chiasmus
  module Discovery
    struct DartExtractor < QueryExtractor
      def language : String
        "dart"
      end

      def extensions : Array(String)
        [".dart"]
      end

      def grammar_language : String
        "dart"
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_definition name: (identifier) @name) @def",
          "function" => "(function_signature name: (identifier) @name) @def",
        }
      end
    end
  end
end
