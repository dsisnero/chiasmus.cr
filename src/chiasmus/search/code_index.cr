# Multi-language code index that bridges the Discovery pipeline
# (18 language extractors producing Discovery::Item[]) to semantic search
# via Crig's InMemoryVectorStore(D) with generic document types.
#
# Design inspired by Crig's builder pattern and generic InMemoryVectorStore.

require "json"
require "digest/sha256"
require "../merkle_tree"

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
      # SHA-256(content) — used for Merkle tree leaf & embedding cache key.
      # Not serialized — derived from text which IS serialized.
      @[JSON::Field(ignore: true)]
      getter content_hash : Bytes = Bytes.new(0)

      # Recompute content_hash from text after JSON deserialization.
      def after_initialize
        @content_hash = Digest::SHA256.digest(@text)
      end

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
        @content_hash = Digest::SHA256.digest(@text)
      end

      # Hex-encoded content hash for embedding cache keys.
      def content_hash_hex : String
        @content_hash.hexstring
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
      # Merkle root hash — cryptographic summary of all document hashes.
      # Enables O(1) index state comparison across rebuilds.
      getter merkle_root : Bytes?
      getter merkle_tree : MerkleTree?

      def initialize(
        @language : String,
        @documents : Array(CodeDocument) = [] of CodeDocument,
        @merkle_tree : MerkleTree? = nil,
      )
        @merkle_root = @merkle_tree.try(&.root_hash)
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

      # Result of searching the code index.
      record SearchResult,
        score : Float64,
        document : CodeDocument

      def initialize(
        @language : String,
        @documents : Array(CodeDocument) = [] of CodeDocument,
        @merkle_tree : MerkleTree? = nil,
      )
        @merkle_root = @merkle_tree.try(&.root_hash)
      end

      def count : Int32
        @documents.size
      end

      # Create a Builder for a specific language.
      def self.for_language(language : String) : Builder
        Builder.new(language)
      end

      # Compare against a previous index and return only changed documents.
      # O(1) if Merkle roots match; O(n) hash comparison otherwise.
      #
      # Returns a DiffResult with added, removed, and changed documents.
      # `changed` documents are those whose content_hash differs from the old index.
      record DiffResult,
        added : Array(CodeDocument),
        removed : Array(String),       # ids no longer present
        changed : Array(CodeDocument), # same id, different content_hash
        unchanged : Int32              # count of unchanged documents

      def diff(previous : CodeIndex) : DiffResult
        old_by_id = previous.documents.to_h { |d| {d.id, d} }
        new_by_id = @documents.to_h { |d| {d.id, d} }

        added = [] of CodeDocument
        changed = [] of CodeDocument
        unchanged = 0
        removed = (old_by_id.keys - new_by_id.keys)

        new_by_id.each do |id, doc|
          if old = old_by_id[id]?
            if doc.content_hash == old.content_hash
              unchanged += 1
            else
              changed << doc
            end
          else
            added << doc
          end
        end

        DiffResult.new(added: added, removed: removed, changed: changed, unchanged: unchanged)
      end

      # True if this index has the same Merkle root as another index.
      # O(1) — compares only the root hash, not individual documents.
      def same_state?(other : CodeIndex) : Bool
        r1 = @merkle_root
        r2 = other.merkle_root
        return false if r1.nil? != r2.nil?
        r1 == r2
      end

      # Group documents by file path for file-level change detection.
      # Matches Cursor's approach: hash files first, then drill into
      # individual symbols within changed files.
      #
      # Returns a Hash mapping file path to its Merkle hash (SHA-256
      # of all symbol content_hashes within that file concatenated).
      def file_hashes : Hash(String, Bytes)
        by_file = @documents.group_by(&.file)
        by_file.transform_values do |docs|
          combined = docs.sort_by(&.id).map(&.content_hash).join
          Digest::SHA256.digest(combined.to_slice)
        end
      end

      # Diff files against a previous index — O(#files) via file_hash comparison.
      # Returns arrays of file paths that were added, removed, or changed.
      # Only files in `changed_files` need their symbols re-checked.
      record FileDiff,
        added_files : Array(String),
        removed_files : Array(String),
        changed_files : Array(String),
        unchanged_files : Int32

      def file_diff(previous : CodeIndex) : FileDiff
        old_hashes = previous.file_hashes
        new_hashes = file_hashes

        old_files = old_hashes.keys.to_set
        new_files = new_hashes.keys.to_set

        added = (new_files - old_files).to_a
        removed = (old_files - new_files).to_a

        changed = [] of String
        unchanged = 0
        (old_files & new_files).each do |file|
          if old_hashes[file] == new_hashes[file]
            unchanged += 1
          else
            changed << file
          end
        end

        FileDiff.new(
          added_files: added,
          removed_files: removed,
          changed_files: changed,
          unchanged_files: unchanged,
        )
      end

      # Returns only the documents belonging to the given files.
      def documents_in_files(file_paths : Array(String)) : Array(CodeDocument)
        @documents.select { |d| file_paths.includes?(d.file) }
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

        # Build the CodeIndex with a Merkle tree over document hashes.
        # The Merkle root hash provides O(1) comparison across rebuilds:
        # if root_hash == old_index.merkle_root, nothing changed.
        # If different, compare individual content_hashes to find changed docs.
        def build : CodeIndex
          tree = if @documents.empty?
                   nil
                 else
                   hashes = @documents.map(&.content_hash)
                   MerkleTree.new(hashes)
                 end
          CodeIndex.new(@language, @documents, merkle_tree: tree)
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

        # Prepare embedding text: full AST node chunk if available (Cursor-style),
        # otherwise fall back to line-based snippet.
        private def prepare_text(
          item : Discovery::Item,
          source : String?,
          line : Int32,
        ) : String
          # Prefer AST-based chunking: extract full function/class body
          if source && (bs = item.byte_start) && (be = item.byte_end) && be > bs
            text = source.byte_slice(bs, be - bs)
            if text.includes?('\n')
              # Full AST node — use as-is, capped
              text.size <= @config.max_text_len ? text : text[0...@config.max_text_len]
            else
              # byte range is too narrow (just the name), fall back to snippet
              snippet_from_lines(source, item.name, line)
            end
          else
            snippet_from_lines(source, item.name, line)
          end
        end

        private def snippet_from_lines(source : String?, name : String, line : Int32) : String
          if source
            lines = source.lines
            start = {line - @config.snippet_lines // 2 - 1, 0}.max
            finish = {line + @config.snippet_lines // 2, lines.size}.min
            lines[start...finish].join
          else
            name
          end
        end
      end
    end
  end
end
