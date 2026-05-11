require "../extractor"

module Chiasmus
  module Discovery
    struct ScalaExtractor < QueryExtractor
      def language : String
        "scala"
      end

      def extensions : Array(String)
        [".scala", ".sc"]
      end

      def grammar_language : String
        "scala"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (class_definition name: (identifier) @name) @def
            (object_definition name: (identifier) @name) @def
          QUERY
          "interface" => "(trait_definition name: (identifier) @name) @def",
          "function"  => "(function_definition name: (identifier) @name) @def",
          "test"      => "(function_definition name: (identifier) @name) @def",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "test"
          name.starts_with?("test") || name.ends_with?("Spec") || name.ends_with?("Suite") ? name : nil
        else name
        end
      end
    end
  end
end
