require "../extractor"

module Chiasmus
  module Discovery
    struct RustExtractor < QueryExtractor
      def language : String
        "rust"
      end

      def extensions : Array(String)
        [".rs"]
      end

      def grammar_language : String
        "rust"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (struct_item name: (type_identifier) @name) @def
            (enum_item name: (type_identifier) @name) @def
          QUERY
          "interface" => "(trait_item name: (type_identifier) @name) @def",
          "function"  => "(function_item name: (identifier) @name) @def",
          "const"     => "(const_item name: (identifier) @name) @def",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "function"
          # If inside impl_item, it's a method — handled via method detection below
          name
        else
          name
        end
      end

      def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Array(Item)
        items = [] of Item
        lang = TreeSitterManager::GrammarLoader.load_language(grammar_language)
        return items unless lang

        # Process function items — split into functions vs methods (in impl)
        func_query_src = "(function_item name: (identifier) @name) @def"
        func_query = TreeSitter::Query.new(lang, func_query_src)
        cursor = TreeSitter::QueryCursor.new(func_query)
        cursor.exec(root_node) do |capture|
          next unless capture.rule == "name"
          name = capture.node.text(source)

          if rust_test_function?(capture.node, source)
            qualified_name = (enclosing_modules(capture.node, source) + [name]).join("::")
            items << Item.new(id: "#{file_path}::test::#{qualified_name}", kind: "test", scope: "test", name: qualified_name, file: file_path)
          elsif inside_impl?(capture.node)
            impl_type = find_enclosing_impl_type(capture.node, source)
            full_name = impl_type ? "#{impl_type}.#{name}" : name
            items << Item.new(id: "#{file_path}::method::#{full_name}", kind: "method", scope: "source", name: full_name, file: file_path)
          else
            items << Item.new(id: "#{file_path}::function::#{name}", kind: "function", scope: "source", name: name, file: file_path)
          end
        end

        # Process class, interface, const queries
        ["class", "interface", "const"].each do |kind|
          query_src = queries[kind]?
          next unless query_src
          query = TreeSitter::Query.new(lang, query_src)
          cursor2 = TreeSitter::QueryCursor.new(query)
          cursor2.exec(root_node) do |capture|
            next unless capture.rule == "name"
            name = capture.node.text(source)
            filtered = post_filter(kind, name, capture.node, source)
            next unless filtered
            items << Item.new(id: "#{file_path}::#{kind}::#{filtered}", kind: kind, scope: "source", name: filtered, file: file_path)
          end
        end

        deduplicate(items)
      end

      private def inside_impl?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          return true if current.type == "impl_item"
          return false if current.type == "source_file"
          current = current.parent
        end
        false
      end

      private def rust_test_function?(name_node : TreeSitter::Node, source : String) : Bool
        function = name_node.parent
        return false unless function && function.type == "function_item"
        sibling = function.prev_sibling
        while sibling && sibling.type.in?("attribute_item", "line_comment", "block_comment")
          if sibling.type == "attribute_item" && sibling.text(source).matches?(/\A#\[\s*(?:[A-Za-z_][A-Za-z_0-9]*::)*test\b/)
            return true
          end
          sibling = sibling.prev_sibling
        end
        false
      end

      private def enclosing_modules(node : TreeSitter::Node, source : String) : Array(String)
        modules = [] of String
        current = node.parent
        while current
          if current.type == "mod_item"
            if name = current.child_by_field_name("name")
              modules.unshift(name.text(source))
            end
          end
          current = current.parent
        end
        modules
      end

      private def find_enclosing_impl_type(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          if current.type == "impl_item"
            type_node = current.child_by_field_name("type")
            return type_node.try(&.text(source))
          end
          current = current.parent
        end
        nil
      end

      private def deduplicate(items : Array(Item)) : Array(Item)
        seen = Set(String).new
        items.select { |item| seen.add?(item.id) }
      end
    end
  end
end
