require "../extractor"

module Chiasmus
  module Discovery
    struct JavaExtractor < QueryExtractor
      def language : String
        "java"
      end

      def extensions : Array(String)
        [".java"]
      end

      def grammar_language : String
        "java"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (class_declaration name: (identifier) @name) @def
            (enum_declaration name: (identifier) @name) @def
          QUERY
          "interface" => "(interface_declaration name: (identifier) @name) @def",
          "method"    => "(method_declaration name: (identifier) @name) @def",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method(node, source, name) : name
        else
          name
        end
      end
    end
  end
end
