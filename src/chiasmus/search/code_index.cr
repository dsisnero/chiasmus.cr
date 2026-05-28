# Multi-language code index that bridges the Discovery pipeline
# (18 language extractors producing Discovery::Item[]) to semantic search
# via Crig's InMemoryVectorStore(D) with generic document types.
#
# Design inspired by Crig's builder pattern and generic InMemoryVectorStore.

require "json"

module Chiasmus
  module Search
    # Rich document produced from Discovery::Item + source content,
    # stored alongside its embedding vector in the vector store.
    struct CodeDocument
      include JSON::Serializable

      getter id : String
      getter name : String
      getter kind : String
      getter language : String
      getter file : String
      getter line : Int32
      getter signature : String?
      getter leading_doc : String?
      getter text : String

      def initialize(
        @id : String,
        @name : String,
        @kind : String,
        @language : String,
        @file : String,
        @line : Int32,
        @text : String,
        @signature : String? = nil,
        @leading_doc : String? = nil,
      )
      end
    end

    # Per-language configuration for code indexing.
    # Controls which symbol kinds are indexed and how text is prepared.
    struct CodeIndexConfig
      getter indexed_kinds : Set(String)
      getter max_text_len : Int32
      getter snippet_lines : Int32

      def initialize(
        @indexed_kinds : Set(String) = Set{"function", "method"},
        @max_text_len : Int32 = 2000,
        @snippet_lines : Int32 = 6,
      )
      end

      # Returns true if the given kind should be indexed.
      def includes_kind?(kind : String) : Bool
        @indexed_kinds.includes?(kind)
      end

      DEFAULT_CONFIGS = {
        "go"         => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "typescript" => new(indexed_kinds: ["function", "method", "class", "interface", "type"].to_set),
        "javascript" => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "python"     => new(indexed_kinds: ["function", "class", "interface"].to_set),
        "java"       => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "rust"       => new(indexed_kinds: ["function", "class", "interface"].to_set),
        "ruby"       => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "crystal"    => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "c"          => new(indexed_kinds: ["function"].to_set),
        "cpp"        => new(indexed_kinds: ["function", "class", "interface"].to_set),
        "csharp"     => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "kotlin"     => new(indexed_kinds: ["function", "class"].to_set),
        "scala"      => new(indexed_kinds: ["function", "class", "interface"].to_set),
        "php"        => new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
        "bash"       => new(indexed_kinds: ["function"].to_set),
        "dart"       => new(indexed_kinds: ["function", "class"].to_set),
        "perl"       => new(indexed_kinds: ["function", "class"].to_set),
        "protobuf"   => new(indexed_kinds: ["class"].to_set),
      }

      # Returns a reasonable default config for the given language.
      # Falls back to function+method for unknown languages.
      def self.defaults_for(language : String) : CodeIndexConfig
        DEFAULT_CONFIGS[language]? || new
      end
    end

    # Multi-language code index built from Discovery items.
    # Holds CodeDocuments and provides search over embeddings.
    class CodeIndex
      getter language : String
      getter documents : Array(CodeDocument)

      # Result of searching the code index.
      record SearchResult,
        score : Float64,
        document : CodeDocument

      def initialize(@language : String, @documents : Array(CodeDocument) = [] of CodeDocument)
      end

      def count : Int32
        @documents.size
      end

      # Search for documents matching the query string.
      # Uses keyword-in-text scoring (TF over the document text).
      # Returns results sorted by descending score.
      #
      # For vector-based semantic search, supply an embedding model:
      #   index.vector_search(embedding_model, query, top_k)
      def search(query : String, top_k : Int32 = 10) : Array(SearchResult)
        return [] of SearchResult if @documents.empty? || query.empty?

        query_terms = query.downcase.split
        results = @documents.map do |doc|
          text_lower = doc.text.downcase
          score = query_terms.sum { |term| text_lower.scan(term).size.to_f64 }
          SearchResult.new(score: score, document: doc)
        end

        results.select! { |r| r.score > 0 }
        results.sort_by! { |r| -r.score }
        results.first(top_k)
      end

      # Create a Builder for a specific language.
      def self.for_language(language : String) : Builder
        Builder.new(language)
      end

      # Fluent builder matching Crig's InMemoryVectorStoreBuilder pattern.
      struct Builder
        getter language : String
        getter config : CodeIndexConfig
        getter documents : Array(CodeDocument)

        def initialize(@language : String)
          @config = CodeIndexConfig.defaults_for(@language)
          @documents = [] of CodeDocument
        end

        # Override the default configuration for this language.
        def with_config(@config : CodeIndexConfig) : self
          self
        end

        # Convert Discovery::Item[] to CodeDocument[] using source content.
        # Filters by config.indexed_kinds, extracts snippet text, resolves
        # line numbers from item ids.
        def from_items(
          items : Array(Discovery::Item),
          sources : Hash(String, String),
        ) : self
          items.each do |item|
            next if item.id.empty?
            next unless @config.includes_kind?(item.kind)

            source = sources[item.file]?
            line = extract_line(item.name, source)
            text = prepare_text(item, source, line)

            @documents << CodeDocument.new(
              id: item.id,
              name: item.name,
              kind: item.kind,
              language: @language,
              file: item.file,
              line: line,
              text: text,
            )
          end
          self
        end

        # Build the CodeIndex. Embedding is deferred to search time.
        def build : CodeIndex
          CodeIndex.new(@language, @documents)
        end

        # Extract line number from Discovery item id by searching source content.
        # Discovery items don't carry line numbers, so we find the symbol
        # name in the source file.
        private def extract_line(name : String, source : String?) : Int32
          return 1 unless source
          source.lines.each_with_index(1) do |line_text, idx|
            return idx if line_text.includes?(name)
          end
          1
        end

        # Prepare embedding text: name + snippet, capped at max_text_len.
        private def prepare_text(
          item : Discovery::Item,
          source : String?,
          line : Int32,
        ) : String
          snippet = if source
                      lines = source.lines
                      start = {line - @config.snippet_lines // 2 - 1, 0}.max
                      finish = {line + @config.snippet_lines // 2, lines.size}.min
                      lines[start...finish].join
                    else
                      item.name
                    end

          text = [item.name, snippet].reject(&.empty?).join("\n")
          text.size <= @config.max_text_len ? text : text[0...@config.max_text_len]
        end
      end
    end
  end
end
