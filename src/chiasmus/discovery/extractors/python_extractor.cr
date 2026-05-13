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

      def predicate_queries : Hash(String, String)
        {
          "definition.constructor" => "(class_definition body: (block (function_definition name: (identifier) @name (#eq? @name \"__init__\"))))",
          "definition.import"      => <<-QUERY,
            (import_statement name: (dotted_name (identifier) @name))
            (import_from_statement name: (dotted_name (identifier) @name))
            (aliased_import name: (identifier) @name alias: (identifier) @parent)
          QUERY
          "reference.call"      => "(call function: (identifier) @name)",
          "reference.call_attr" => "(call function: (attribute attribute: (identifier) @name object: (identifier) @parent))",
          "field"               => "(class_definition body: (block (assignment left: (identifier) @name)))",
        }
      end

      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        case kind
        when "const"
          name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
        when "function"
          if node && inside_class?(node)
            class_name = find_enclosing_class(node, source)
            class_name ? nil : name
          else
            name
          end
        when "test"
          name.starts_with?("test_") ? name : nil
        when "definition.constructor"
          name == "__init__" ? name : nil
        when "field"
          name
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

        # Process predicate queries for imports, constructors, references
        predicate_queries.each do |kind, query_src|
          process_predicate_query_inline(kind, query_src, root_node, source, file_path, items, lang)
        end

        deduplicate(items)
      end

      private def process_predicate_query_inline(
        kind : String, query_src : String,
        root_node : TreeSitter::Node, source : String,
        file : String, items : Array(Item), lang : TreeSitter::Language,
      ) : Nil
        query = TreeSitter::Query.new(lang, query_src)
        cursor = TreeSitter::QueryCursor.new(query)
        cursor.exec(root_node)

        while match = cursor.next_match
          metadata = {} of String => String
          adjacent = {} of String => Array(TreeSitter::Node)

          next unless PredicateEvaluator.evaluate_match_predicates(query, match, source, metadata, adjacent)

          name = nil
          match.captures.each do |cap|
            if cap.rule == "name"
              name = cap.node.text(source)
              break
            end
          end
          next unless name

          filtered = post_filter(kind, name, nil, source)
          next unless filtered

          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: "source",
            name: filtered,
            file: file
          )
        end
      rescue ex
        # Query errors are non-fatal
      end

      private def inside_class?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          return true if current.type == "class_definition"
          return false if current.type == "module"
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
