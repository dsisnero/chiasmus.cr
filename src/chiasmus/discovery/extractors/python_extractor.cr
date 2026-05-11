require "../extractor"

module Chiasmus
  module Discovery
    struct PythonExtractor < QueryExtractor
      def language : String
        "python"
      end

      def extensions : Array(String)
        [".py"]
      end

      def grammar_language : String
        "python"
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_definition name: (identifier) @name) @def",
          "function" => "(function_definition name: (identifier) @name) @def",
          "const"    => "(expression_statement (assignment left: (identifier) @name)) @def",
          "test"     => "(function_definition name: (identifier) @name) @def",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "function"
          if node && inside_class?(node)
            class_name = find_enclosing_class(node, source)
            class_name ? nil : name # Method → handled as method in function path
          else
            name
          end
        when "test"
          name.starts_with?("test_") ? name : nil
        else
          name
        end
      end

      def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Array(Item)
        items = [] of Item
        lang = GrammarLoader.load_language(grammar_language)
        return items unless lang

        # Use a combined function query and split by context
        func_query_src = "(function_definition name: (identifier) @name) @def"
        func_query = TreeSitter::Query.new(lang, func_query_src)
        cursor = TreeSitter::QueryCursor.new(func_query)
        cursor.exec(root_node) do |capture|
          next unless capture.rule == "name"
          name = capture.node.text(source)

          if name.starts_with?("test_")
            items << Item.new(id: "#{file_path}::test::#{name}", kind: "test", scope: "test", name: name, file: file_path)
            next
          end

          if inside_class?(capture.node)
            class_name = find_enclosing_class(capture.node, source)
            full_name = class_name ? "#{class_name}.#{name}" : name
            items << Item.new(id: "#{file_path}::method::#{full_name}", kind: "method", scope: "source", name: full_name, file: file_path)
          else
            items << Item.new(id: "#{file_path}::function::#{name}", kind: "function", scope: "source", name: name, file: file_path)
          end
        end

        # Class query
        class_query_src = "(class_definition name: (identifier) @name) @def"
        class_query = TreeSitter::Query.new(lang, class_query_src)
        cursor2 = TreeSitter::QueryCursor.new(class_query)
        cursor2.exec(root_node) do |capture|
          next unless capture.rule == "name"
          name = capture.node.text(source)
          items << Item.new(id: "#{file_path}::class::#{name}", kind: "class", scope: "source", name: name, file: file_path)
        end

        # Constant query (UPPERCASE assignments only)
        const_query_src = "(expression_statement (assignment left: (identifier) @name)) @def"
        const_query = TreeSitter::Query.new(lang, const_query_src)
        cursor3 = TreeSitter::QueryCursor.new(const_query)
        cursor3.exec(root_node) do |capture|
          next unless capture.rule == "name"
          name = capture.node.text(source)
          if name =~ /^[A-Z][A-Z0-9_]*$/
            items << Item.new(id: "#{file_path}::const::#{name}", kind: "const", scope: "source", name: name, file: file_path)
          end
        end

        deduplicate(items)
      end

      private def inside_class?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          return true if current.type == "class_definition"
          return false if current.type == "module" # reached top level
          current = current.parent
        end
        false
      end

      private def find_enclosing_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          if current.type == "class_definition"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
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
