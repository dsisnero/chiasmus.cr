require "../extractor"

module Chiasmus
  module Discovery
    struct BashExtractor < QueryExtractor
      def language : String
        "bash"
      end

      def extensions : Array(String)
        [".sh", ".bash"]
      end

      def grammar_language : String
        "bash"
      end

      def queries : Hash(String, String)
        {
          "function" => "(function_definition name: (word) @name) @def",
        }
      end
    end
  end
end
