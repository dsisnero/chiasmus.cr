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
        when "method", "definition.method"
          node ? qualify_method(node, source, name) : name
        when "field", "field_record"
          name
        else
          name
        end
      end
    end
  end
end
