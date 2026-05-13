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

      # Codeium-parse-style enriched queries with custom predicates.
      def predicate_queries : Hash(String, String)
        {
          "definition.type"     => "(type_spec name: (type_identifier) @name type: (type_identifier))",
          "package"             => "(source_file (package_clause (package_identifier) @name))",
          "reference.call"      => "(call_expression function: (identifier) @name)",
          "reference.call_sel"  => "(call_expression function: (selector_expression field: (field_identifier) @name operand: (identifier) @parent))",
          "reference.class"     => "(composite_literal type: (type_identifier) @name)",
          "definition.function" => "((comment)* @doc . (function_declaration name: (identifier) @name parameters: (parameter_list) @codeium.parameters result: _? @codeium.return_type))",
          "definition.method"   => "((comment)* @doc . (method_declaration receiver: (parameter_list (parameter_declaration type: (_) @_)) name: (field_identifier) @name parameters: (parameter_list) @codeium.parameters result: _? @codeium.return_type))",
          "field"               => "(type_declaration (type_spec type: (struct_type (field_declaration_list (field_declaration name: (field_identifier) @name)))))",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method_go(node, source, name) : name
        when "test"
          name.starts_with?("Test") ? name : nil
        when "definition.method"
          node ? qualify_method_go_enriched(node, source, name) : name
        else
          name
        end
      end

      private def qualify_method_go(node : TreeSitter::Node, source : String, name : String) : String
        current = node.parent
        while current
          if current.type == "method_declaration"
            receiver = current.child_by_field_name("receiver")
            if receiver
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

      private def qualify_method_go_enriched(node : TreeSitter::Node, source : String, name : String) : String
        qualify_method_go(node, source, name)
      end
    end
  end
end
