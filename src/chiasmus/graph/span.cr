require "tree_sitter"

module Chiasmus
  module Graph
    # Unified source location spanning byte offsets + line/column positions.
    # Mirrors xberg-io/tree-sitter-language-pack's Span for cross-tool consistency.
    struct Span
      include JSON::Serializable

      getter start_byte : Int32
      getter end_byte : Int32
      getter start_line : Int32
      getter start_column : Int32
      getter end_line : Int32
      getter end_column : Int32

      def initialize(
        @start_byte : Int32,
        @end_byte : Int32,
        @start_line : Int32,
        @start_column : Int32,
        @end_line : Int32,
        @end_column : Int32,
      )
      end

      def self.from_node(node : TreeSitter::Node) : self
        new(
          start_byte: node.start_byte.to_i32,
          end_byte: node.end_byte.to_i32,
          start_line: node.start_point.row.to_i + 1,
          start_column: node.start_point.column.to_i,
          end_line: node.end_point.row.to_i + 1,
          end_column: node.end_point.column.to_i,
        )
      end

      # Builds a span when a line-oriented interchange format does not carry
      # byte offsets or columns. Zeroes explicitly represent unavailable
      # byte/column detail; parsed tree-sitter spans always use `from_node`.
      def self.line_range(start_line : Int, end_line : Int = start_line) : self
        new(
          start_byte: 0,
          end_byte: 0,
          start_line: start_line.to_i32,
          start_column: 0,
          end_line: end_line.to_i32,
          end_column: 0,
        )
      end

      def bytes : Range(Int32, Int32)
        start_byte...end_byte
      end
    end
  end
end
