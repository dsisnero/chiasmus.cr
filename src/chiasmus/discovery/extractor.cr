require "tree_sitter"

module Chiasmus
  module Discovery
    # Abstract base for language-specific symbol extraction.
    # Subclasses define query patterns and post-filter logic.
    #
    # Implements the Strategy pattern: Pipeline depends on this
    # abstraction, not on concrete language extractors.
    abstract struct LanguageExtractor
      abstract def language : String
      abstract def extensions : Array(String)
      abstract def grammar_language : String

      # Extract declarations from a parsed AST.
      # Returns items with stable IDs: {file_path}::{kind}::{name}
      abstract def extract(
        root_node : TreeSitter::Node,
        source : String,
        file_path : String,
      ) : Array(Item)
    end

    # Base class providing tree-sitter query execution helpers.
    #
    # Subclasses override `queries` to return kind→query_pattern mappings
    # and `post_filter` for kind-specific name filtering/transformation.
    abstract struct QueryExtractor < LanguageExtractor
      abstract def queries : Hash(String, String)

      # Post-filter: transform or reject a matched name.
      # Return nil to reject, or a string to set the name.
      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        name
      end

      def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Array(Item)
        items = [] of Item
        file = file_path

        queries.each do |kind, query_src|
          process_query(kind, query_src, root_node, source, file, items)
        end

        deduplicate(items)
      end

      private def process_query(
        kind : String,
        query_src : String,
        root_node : TreeSitter::Node,
        source : String,
        file : String,
        items : Array(Item),
      ) : Nil
        lang = load_grammar_language
        return unless lang

        query = TreeSitter::Query.new(lang, query_src)

        if multi_capture_query?(kind)
          process_multi_capture(kind, query, root_node, source, file, items)
        else
          process_single_capture(kind, query, root_node, source, file, items)
        end
      rescue ex
        # Query errors are non-fatal
      end

      private def process_single_capture(
        kind : String,
        query : TreeSitter::Query,
        root_node : TreeSitter::Node,
        source : String,
        file : String,
        items : Array(Item),
      ) : Nil
        cursor = TreeSitter::QueryCursor.new(query)
        cursor.exec(root_node) do |capture|
          next unless capture.rule == "name"
          name = capture.node.text(source)
          filtered = post_filter(kind, name, capture.node, source)
          next unless filtered

          scope = kind == "test" ? "test" : "source"
          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: scope,
            name: filtered,
            file: file
          )
        end
      end

      private def process_multi_capture(
        kind : String,
        query : TreeSitter::Query,
        root_node : TreeSitter::Node,
        source : String,
        file : String,
        items : Array(Item),
      ) : Nil
        cursor = TreeSitter::QueryCursor.new(query)
        cursor.exec(root_node)
        while match = cursor.next_match
          name = nil
          meta = {} of String => String
          match.captures.each do |cap|
            if cap.rule == "name"
              name = cap.node.text(source)
            elsif cap.rule.starts_with?("meta_")
              meta[cap.rule] = cap.node.text(source)
            end
          end
          next unless name

          filtered = post_filter(kind, name, nil, source)
          next unless filtered

          scope = kind == "test" ? "test" : "source"
          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: scope,
            name: filtered,
            file: file
          )
        end
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end

      private def load_grammar_language : TreeSitter::Language?
        GrammarLoader.load_language(grammar_language)
      end

      private def deduplicate(items : Array(Item)) : Array(Item)
        seen = Set(String).new
        items.select { |item| seen.add?(item.id) }
      end

      # Find the enclosing class name for a method node
      private def find_enclosing_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          case current.type
          when "class_declaration", "abstract_class_declaration",
               "class_definition", "class_def", "struct_def",
               "struct_item", "impl_item"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          when "class_body", "block", "declaration_list"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end

      # Qualify method name with enclosing class
      def qualify_method(node : TreeSitter::Node, source : String, name : String) : String
        class_name = find_enclosing_class(node, source)
        class_name ? "#{class_name}.#{name}" : name
      end
    end
  end
end
