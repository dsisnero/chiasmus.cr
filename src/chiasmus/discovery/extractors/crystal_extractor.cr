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
            (c_struct_def name: (constant) @name) @def
            (union_def name: (constant) @name) @def
          QUERY
          "interface" => "(module_def name: (constant) @name) @def",
          "enum"      => "(enum_def name: (constant) @name) @def",
          "type"      => <<-QUERY,
            (alias name: (constant) @name) @def
            (type_def name: (constant) @name) @def
          QUERY
          "method" => <<-QUERY,
            (method_def name: (identifier) @name) @def
            (abstract_method_def name: (identifier) @name) @def
          QUERY
          "macro"      => "(macro_def name: (identifier) @name) @def",
          "const"      => "(const_assign lhs: (constant) @name) @def",
          "lib"        => "(lib_def name: (constant) @name) @def",
          "function"   => "(fun_def name: (identifier) @name) @def",
          "annotation" => "(annotation_def name: (constant) @name) @def",
          "field"      => <<-QUERY,
            (assign lhs: (instance_var) @name)
            (assign lhs: (class_var) @name)
            (type_declaration (instance_var) @name)
            (type_declaration (class_var) @name)
          QUERY
        }
      end

      def predicate_queries : Hash(String, String)
        {
          # require "foo" or require "./foo"
          "definition.import" => "(require (string) @name)",
          # include Foo, include Enumerable(Int32), extend Foo, extend self
          "definition.module" => <<-QUERY,
            (include (constant) @name)
            (include (generic_instance_type (constant) @name))
            (extend (constant) @name)
            (extend (generic_instance_type (constant) @name))
          QUERY
          # obj.method call with receiver (dot call) — for reference.call_sel
          "reference.call_sel" => <<-QUERY,
            (call receiver: (identifier) @parent method: (identifier) @name)
            (call receiver: (constant) @parent method: (identifier) @name)
            (call receiver: (self) @parent method: (identifier) @name)
            (call receiver: (instance_var) @parent method: (identifier) @name)
          QUERY
          # bare method call (no receiver) — for reference.call
          "reference.call" => "(call method: (identifier) @name)",
          # constructor call: Foo.new or Foo.new(...)
          "reference.class" => "(call receiver: (constant) @parent method: (identifier) @name (#eq? @name \"new\"))",
          # operator calls: a + b, a == b
          "reference.call_op" => "(call method: (operator) @name)",
          # implicit object call: &.method in blocks
          "reference.call_imp" => "(implicit_object_call method: (identifier) @name)",
          # index call: obj[key]
          "reference.call_idx" => "(index_call receiver: (identifier) @parent arguments: (argument_list) @codeium.parameters)",
          # Enriched method definition with params and return type
          "definition.method" => <<-QUERY,
            (method_def
              name: (identifier) @name
              params: (param_list) @codeium.parameters
              type: (_)? @codeium.return_type) @definition.method
            (abstract_method_def
              name: (identifier) @name
              params: (param_list) @codeium.parameters
              type: (_)? @codeium.return_type) @definition.method
          QUERY
          # Enriched class/struct definition
          "definition.class" => <<-QUERY,
            (class_def name: (constant) @name) @definition.class
            (struct_def name: (constant) @name) @definition.class
          QUERY
          # Enriched module definition
          "definition.module_def" => <<-QUERY,
            (module_def name: (constant) @name) @definition.module_def
          QUERY
          # Enriched enum definition
          "definition.enum" => <<-QUERY,
            (enum_def name: (constant) @name) @definition.enum
          QUERY
          # Enriched type alias
          "definition.type" => <<-QUERY,
            (alias name: (constant) @name) @definition.type
            (type_def name: (constant) @name) @definition.type
          QUERY
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method(node, source, name) : name
        when "definition.import"
          name.strip(%("')).presence
        when "const"
          # Only UPPER_CASE constants, reject regular variable assignments
          name.matches?(/^[A-Z][A-Z0-9_]*$/) ? name : nil
        when "macro"
          # Macros always start with lowercase (convention)
          name.matches?(/^_?[a-z]/) ? name : nil
        when "field"
          # Strip @ and @@ prefix for cleaner field names, keep raw for ids
          name
        when "definition.module"
          # For generic_instance_type includes, extract the base name
          name
        else name
        end
      end
    end
  end
end
