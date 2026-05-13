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

      def predicate_queries : Hash(String, String)
        {
          # require "foo" or require "./foo"
          "definition.import" => "(require (string) @name)",
          # include Foo or extend Foo
          "definition.module" => <<-QUERY,
            (include (constant) @name)
            (extend (constant) @name)
          QUERY
          # obj.method call with receiver (dot call) — for reference.call_sel
          "reference.call_sel" => "(call receiver: (identifier) @parent method: (identifier) @name)",
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
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "method"
          node ? qualify_method(node, source, name) : name
        when "definition.import"
          # Strip quotes from require path for clean display
          name.strip(%("')).presence
        else name
        end
      end
    end
  end
end
