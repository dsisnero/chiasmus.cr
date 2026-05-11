require "../extractor"

module Chiasmus
  module Discovery
    struct GoExtractor < QueryExtractor
      def language : String
        "go"
      end

      def extensions : Array(String)
        [".go"]
      end

      def grammar_language : String
        "go"
      end

      def queries : Hash(String, String)
        {
          "class"     => "(type_spec name: (type_identifier) @name type: (struct_type)) @def",
          "interface" => "(type_spec name: (type_identifier) @name type: (interface_type)) @def",
          "function"  => "(function_declaration name: (identifier) @name) @def",
          "method"    => "(method_declaration name: (field_identifier) @name) @def",
          "test"      => "(function_declaration name: (identifier) @name) @def",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method_go(node, source, name) : name
        when "test"
          name.starts_with?("Test") ? name : nil
        else
          name
        end
      end

      private def qualify_method_go(node : TreeSitter::Node, source : String, name : String) : String
        # Find the method_declaration in the AST and extract receiver type
        current = node.parent
        while current
          if current.type == "method_declaration"
            receiver = current.child_by_field_name("receiver")
            if receiver
              # receiver is (parameter_list (parameter_declaration type: (type_identifier)))
              receiver.children.each do |child|
                if child.type == "parameter_declaration"
                  type_node = child.child_by_field_name("type")
                  if type_node
                    type_name = type_node.text(source).lchop('*')
                    return "#{type_name}.#{name}"
                  end
                end
              end
            end
            break
          end
          current = current.parent
        end
        name
      end
    end
  end
end
