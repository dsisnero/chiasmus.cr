require "tree_sitter"
require "./predicate_evaluator"

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
    #
    # To use codeium-parse-style predicate queries with enriched captures
    # (doc, params, return_type, lineage), override `predicate_queries`
    # which returns kind→query_source mappings processed with predicate evaluation.
    abstract struct QueryExtractor < LanguageExtractor
      @@cache_mutex = Mutex.new
      @@language_cache = {} of String => TreeSitter::Language?
      @@compiled_query_cache = {} of Tuple(String, String) => TreeSitter::Query

      abstract def queries : Hash(String, String)

      # Override to add codeium-parse-style queries with custom predicates.
      # These queries support @doc, @codeium.parameters, @codeium.return_type,
      # @parent, and custom predicate evaluation.
      def predicate_queries : Hash(String, String)
        {} of String => String
      end

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

        predicate_queries.each do |kind, query_src|
          process_predicate_query(kind, query_src, root_node, source, file, items)
        end

        deduplicate(items)
      end

      def clear_caches_for_test : Nil
        @@cache_mutex.synchronize do
          @@language_cache.clear
          @@compiled_query_cache.clear
        end
      end

      def cache_counts_for_test : NamedTuple(languages: Int32, queries: Int32)
        @@cache_mutex.synchronize do
          {
            languages: @@language_cache.size,
            queries:   @@compiled_query_cache.size,
          }
        end
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

        query = load_compiled_query(lang, query_src)
        return unless query

        if multi_capture_query?(kind)
          process_multi_capture(kind, query, root_node, source, file, items)
        else
          process_single_capture(kind, query, root_node, source, file, items)
        end
      rescue ex
        # Query errors are non-fatal
      end

      private def process_predicate_query(
        kind : String,
        query_src : String,
        root_node : TreeSitter::Node,
        source : String,
        file : String,
        items : Array(Item),
      ) : Nil
        lang = load_grammar_language
        return unless lang

        query = load_compiled_query(lang, query_src)
        return unless query
        cursor = TreeSitter::QueryCursor.new(query)
        cursor.exec(root_node)

        while match = cursor.next_match
          metadata = {} of String => String
          adjacent = {} of String => Array(TreeSitter::Node)

          # Evaluate custom predicates
          next unless PredicateEvaluator.evaluate_match_predicates(query, match, source, metadata, adjacent)

          name = extract_name_from_match(match, source, kind)
          next unless name

          filtered = post_filter(kind, name, nil, source)
          next unless filtered

          scope = kind.starts_with?("reference.") ? "source" : (kind == "test" ? "test" : "source")
          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: scope,
            name: filtered,
            file: file
          )

          # Extract doc comments as documentation items
          # NB: doc capture is available via match.captures for consumers
          # that need doc text via PredicateEvaluator.doc_text

          # Extract params as additional items
          params_cap = match.captures.find(&.rule.==("codeium.parameters"))
          if params_cap
            params_text = params_cap.node.text(source)
            items << Item.new(
              id: "#{file}::params::#{filtered}",
              kind: "params",
              scope: scope,
              name: params_text,
              file: file
            )
          end

          # Extract return type
          return_cap = match.captures.find(&.rule.==("codeium.return_type"))
          if return_cap
            return_text = return_cap.node.text(source)
            items << Item.new(
              id: "#{file}::return_type::#{filtered}",
              kind: "return_type",
              scope: scope,
              name: return_text,
              file: file
            )
          end
        end
      rescue ex
        # Query errors are non-fatal
      end

      private def extract_name_from_match(match : TreeSitter::Match, source : String, kind : String) : String?
        # Standard name capture
        name_cap = match.captures.find(&.rule.==("name"))
        return name_cap.node.text(source) if name_cap

        # Fallback: use the first capture whose rule starts with the kind prefix
        match.captures.each do |cap|
          if cap.rule.starts_with?("definition.") || cap.rule.starts_with?("reference.")
            return cap.node.text(source)
          end
        end

        nil
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

          # Walk to parent for full declaration byte range (Cursor-style AST chunking)
          def_node = find_definition_parent(capture.node, kind)

          scope = kind == "test" ? "test" : "source"
          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: scope,
            name: filtered,
            file: file,
            span: def_node.try { |definition_node| Graph::Span.from_node(definition_node) },
          )
        end
      end

      # Walk up from a capture node to find the enclosing definition node.
      # Looks for parent nodes matching the expected kind (function_declaration,
      # class_declaration, etc.). Falls back to the name node itself.
      private def find_definition_parent(node : TreeSitter::Node, kind : String) : TreeSitter::Node
        expected = case kind
                   when "function", "test" then {"function_declaration", "method_declaration"}
                   when "method"           then "method_declaration"
                   when "class"            then {"class_declaration", "type_spec", "struct_specifier", "class_definition", "class_body"}
                   when "interface"        then {"interface_declaration", "interface_type", "trait_declaration", "interface_definition"}
                   when "enum"             then {"enum_declaration", "enum_definition"}
                   when "type"             then "type_alias_declaration"
                   when "const"            then {"lexical_declaration", "variable_declaration", "field_declaration"}
                   else
                     nil
                   end

        current = node
        while parent = current.parent
          if expected_matches?(parent, expected)
            return parent
          end
          current = parent
        end
        node
      end

      private def expected_matches?(node : TreeSitter::Node, expected) : Bool
        case expected
        when String then node.type == expected
        when Array  then expected.includes?(node.type)
        else             false
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
          name_node = nil
          meta = {} of String => String
          match.captures.each do |cap|
            if cap.rule == "name"
              name = cap.node.text(source)
              name_node = cap.node
            elsif cap.rule.starts_with?("meta_")
              meta[cap.rule] = cap.node.text(source)
            end
          end
          next unless name

          filtered = post_filter(kind, name, nil, source)
          next unless filtered

          def_node = name_node ? find_definition_parent(name_node, kind) : nil

          scope = kind == "test" ? "test" : "source"
          items << Item.new(
            id: "#{file}::#{kind}::#{filtered}",
            kind: kind,
            scope: scope,
            name: filtered,
            file: file,
            span: def_node.try { |definition_node| Graph::Span.from_node(definition_node) },
          )
        end
      end

      private def multi_capture_query?(kind : String) : Bool
        kind == "test"
      end

      private def load_grammar_language : TreeSitter::Language?
        grammar = grammar_language
        @@cache_mutex.synchronize do
          return @@language_cache[grammar]? if @@language_cache.has_key?(grammar)
        end

        lang = TreeSitterManager::GrammarLoader.load_language(grammar)
        @@cache_mutex.synchronize { @@language_cache[grammar] = lang }
        lang
      end

      private def load_compiled_query(lang : TreeSitter::Language, query_src : String) : TreeSitter::Query?
        return TreeSitter::Query.new(lang, query_src) if isolated_query_instance_required?

        cache_key = {grammar_language, query_src}
        @@cache_mutex.synchronize do
          if cached = @@compiled_query_cache[cache_key]?
            return cached
          end
        end

        query = TreeSitter::Query.new(lang, query_src)
        @@cache_mutex.synchronize { @@compiled_query_cache[cache_key] = query }
        query
      rescue
        nil
      end

      private def isolated_query_instance_required? : Bool
        {% if flag?(:execution_context) %}
          Fiber::ExecutionContext.current != Fiber::ExecutionContext.default
        {% else %}
          false
        {% end %}
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
