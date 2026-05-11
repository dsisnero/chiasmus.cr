require "../extractor"

module Chiasmus
  module Discovery
    struct CrystalExtractor < QueryExtractor
      def language : String
        "crystal"
      end

      def extensions : Array(String)
        [".cr"]
      end

      def grammar_language : String
        "crystal"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (class_def name: (constant) @name) @def
            (struct_def name: (constant) @name) @def
          QUERY
          "interface" => "(module_def name: (constant) @name) @def",
          "method"    => <<-QUERY,
            (method_def name: (identifier) @name) @def
            (abstract_method_def name: (identifier) @name) @def
          QUERY
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method(node, source, name) : name
        else name
        end
      end
    end
  end
end
