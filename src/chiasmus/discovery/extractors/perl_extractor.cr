require "../extractor"

module Chiasmus
  module Discovery
    struct PerlExtractor < QueryExtractor
      def language : String
        "perl"
      end

      def extensions : Array(String)
        [".pl", ".pm"]
      end

      def grammar_language : String
        "perl"
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_statement name: (package) @name) @def",
          "function" => <<-QUERY,
            (subroutine_declaration_statement name: (bareword) @name) @def
            (method_declaration_statement name: (bareword) @name) @def
          QUERY
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.import" => "(use_statement module: (package) @name)",
        }
      end
    end
  end
end
