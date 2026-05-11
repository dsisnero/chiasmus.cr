require "../extractor"

module Chiasmus
  module Discovery
    struct RubyExtractor < QueryExtractor
      def language : String
        "ruby"
      end

      def extensions : Array(String)
        [".rb"]
      end

      def grammar_language : String
        "ruby"
      end

      def queries : Hash(String, String)
        {
          "class"     => "(class name: (constant) @name) @def",
          "interface" => "(module name: (constant) @name) @def",
          "method"    => <<-QUERY,
            (method name: (identifier) @name) @def
            (singleton_method name: (identifier) @name) @def
          QUERY
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method_ruby(node, source, name) : name
        else name
        end
      end

      private def qualify_method_ruby(node : TreeSitter::Node, source : String, name : String) : String
        class_name = find_enclosing_ruby_class(node, source)
        class_name ? "#{class_name}.#{name}" : name
      end

      private def find_enclosing_ruby_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          case current.type
          when "class", "module"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          when "body_statement"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end
    end
  end
end
