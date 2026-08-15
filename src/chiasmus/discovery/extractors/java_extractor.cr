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
            (record_declaration name: (identifier) @name) @def
          QUERY
          "enum"      => "(enum_declaration name: (identifier) @name) @def",
          "interface" => "(interface_declaration name: (identifier) @name) @def",
          "method"    => "(method_declaration name: (identifier) @name) @def",
          "function"  => "(method_declaration name: (identifier) @name) @def",
          "const"     => "(field_declaration declarator: (variable_declarator name: (identifier) @name))",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "package"                => "(package_declaration name: (identifier) @name)",
          "definition.constructor" => "(constructor_declaration name: (identifier) @name parameters: (formal_parameters) @codeium.parameters)",
          "definition.method"      => "((block_comment)* @doc . (method_declaration name: (identifier) @name parameters: (formal_parameters) @codeium.parameters))",
          "field"                  => "(class_declaration (class_body (field_declaration declarator: (variable_declarator name: (identifier) @name))))",
          "field_record"           => "(record_declaration (formal_parameters (formal_parameter name: (identifier) @name)))",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          filter_method(name, node, source)
        when "function"
          filter_function(name, node)
        when "const"
          filter_const(name, node, source)
        when "definition.method", "field", "field_record"
          name
        else
          name
        end
      end

      private def filter_method(name : String, node : TreeSitter::Node?, source : String) : String?
        return nil if node && !inside_class_body?(node)
        node ? qualify_method(node, source, name) : name
      end

      private def filter_function(name : String, node : TreeSitter::Node?) : String?
        return nil if node && inside_class_body?(node)
        name
      end

      private def filter_const(name : String, node : TreeSitter::Node?, source : String) : String?
        return nil unless name =~ /^[A-Z][A-Z0-9_]*$/
        field = node.try { |name_node| find_field_declaration(name_node) }
        return nil unless field && static_final?(field, source)
        name
      end

      # A Java method declared outside any class/interface/enum body is a
      # top-level function; everything else is an instance/static method.
      private def inside_class_body?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          t = current.type
          return true if t == "class_body" || t == "interface_body" || t == "enum_body"
          return false if t == "program"
          current = current.parent
        end
        false
      end

      private def find_field_declaration(node : TreeSitter::Node) : TreeSitter::Node?
        current = node.parent
        while current
          return current if current.type == "field_declaration"
          return nil if current.type == "program" || current.type == "class_body"
          current = current.parent
        end
        nil
      end

      private def static_final?(field_node : TreeSitter::Node, source : String) : Bool
        keywords = [] of String
        (0...field_node.named_child_count).each do |i|
          child = field_node.named_child(i)
          next unless child && child.type == "modifiers"
          keywords = child.text(source).split
          break
        end
        keywords.includes?("static") && keywords.includes?("final")
      end
    end
  end
end
