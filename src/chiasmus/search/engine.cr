# Ported from vendor/chiasmus/src/search/engine.ts
#
# Search engine: build an embedding corpus from a CodeGraph + source,
# run a semantic query via a pluggable embedding adapter (Crig::EmbeddingModelDyn),
# return top-K hits.

require "../graph/types"
require "../graph/chunking"
require "./embedding_cache"

module Chiasmus
  module Search
    SNIPPET_LINES =    6
    MAX_TEXT_LEN  = 2000

    record SearchCorpusEntry,
      id : String,
      name : String,
      file : String,
      line : Int32,
      line_end : Int32,
      signature : String?,
      leading_doc : String?,
      text : String

    record SearchHit,
      id : String,
      name : String,
      file : String,
      line : Int32,
      line_end : Int32,
      signature : String?,
      leading_doc : String?,
      score : Float64

    module SearchEngine
      extend self

      def build_search_corpus(
        graph : Graph::CodeGraph,
        files : Hash(String, String),
      ) : Array(SearchCorpusEntry)
        out = [] of SearchCorpusEntry
        file_doc = extract_file_docs(graph)
        chunk_cache = Hash(String, Array(Graph::Chunking::CodeChunk)).new

        graph.defines.each do |definition|
          next unless definition.kind.function? || definition.kind.method?
          content = files[definition.file]?
          next unless content

          doc = file_doc[definition.file]?
          snippet = snippet_for_define(definition, content, chunk_cache)
          parts = [definition.name] of String
          if doc
            parts << doc
          end
          parts << snippet
          text = parts.join("\n")[0, MAX_TEXT_LEN]

          out << SearchCorpusEntry.new(
            id: make_entry_id(definition),
            name: definition.name,
            file: definition.file,
            line: definition.span.start_line,
            line_end: definition.span.end_line,
            signature: nil,
            leading_doc: doc,
            text: text,
          )
        end

        out
      end

      # Run semantic search using Crig's embedding model for vector generation.
      # Uses linear-scan cosine similarity internally (fine for repos under ~10k
      # callable defines). Prefer Crig::InMemoryVectorStore for larger corpora.
      def run_search(
        query : String,
        corpus : Array(SearchCorpusEntry),
        model : Crig::Embeddings::EmbeddingModel,
        top_k : Int32,
        cache : EmbeddingCache? = nil,
      ) : Array(SearchHit)
        return [] of SearchHit if corpus.empty?

        dim = model.ndims

        # Collect texts to embed, using cache for hits
        to_embed = [] of String
        to_embed_idx = [] of Int32
        vectors = Array(Array(Float64)?).new(corpus.size, nil)

        corpus.each_with_index do |entry, i|
          hit = cache.try(&.get(entry.text))
          if hit && hit.size == dim
            vectors[i] = hit
          else
            to_embed << entry.text
            to_embed_idx << i
          end
        end

        # Embed missing texts via Crig model
        unless to_embed.empty?
          crig_embeddings = model.embed_texts(to_embed)
          crig_embeddings.each_with_index do |emb, j|
            idx = to_embed_idx[j]
            vec = emb.vec.dup
            vectors[idx] = vec
            cache.try(&.put(to_embed[j], vec))
          end
        end

        # Embed query
        query_vec = model.embed_text(query).vec

        # Cosine similarity search
        scored = [] of {Float64, Int32}
        vectors.each_with_index do |vec, i|
          next unless vec
          score = cosine_similarity(query_vec, vec)
          scored << {score, i}
        end

        scored.sort_by! { |score, _entry_index| -score }
        scored.first(top_k).compact_map do |score, i|
          entry = corpus[i]?
          next unless entry
          SearchHit.new(
            id: entry.id,
            name: entry.name,
            file: entry.file,
            line: entry.line,
            line_end: entry.line_end,
            signature: entry.signature,
            leading_doc: entry.leading_doc,
            score: score,
          )
        end
      end

      private def make_entry_id(d : Graph::DefinesFact) : String
        "#{d.file}##{d.name}##{d.span.start_line}"
      end

      private def snippet_around(source : String, start_line : Int32) : String
        lines = source.lines
        start = Math.max(0, start_line - 1)
        finish = Math.min(lines.size, start + SNIPPET_LINES)
        lines[start...finish].join
      end

      private def snippet_for_define(
        define : Graph::DefinesFact,
        source : String,
        chunk_cache : Hash(String, Array(Graph::Chunking::CodeChunk)),
      ) : String
        chunks = chunk_cache[define.file]? || begin
          computed = Graph::Chunking.chunk_source(source, define.file, MAX_TEXT_LEN)
          chunk_cache[define.file] = computed
          computed
        rescue
          [] of Graph::Chunking::CodeChunk
        end

        chunk = chunks.find do |candidate|
          line = define.span.start_line
          candidate.span.start_line <= line && line <= candidate.span.end_line
        end
        return snippet_around(source, define.span.start_line) unless chunk

        chunk_parts = [] of String
        unless chunk.context.context_path.empty?
          chunk_parts << chunk.context.context_path.join("::")
        end
        unless chunk.context.comments.empty?
          chunk_parts << chunk.context.comments.map(&.text).join("\n")
        end
        body = if chunk.context.symbols_defined.size > 1 ||
                  chunk.span.start_line < define.span.start_line ||
                  define.span.end_line < chunk.span.end_line
                 snippet_between(source, define.span.start_line, define.span.end_line)
               else
                 chunk.content
               end
        chunk_parts << body
        chunk_parts.join("\n")
      end

      private def snippet_between(source : String, start_line : Int32, end_line : Int32) : String
        lines = source.lines
        start = Math.max(0, start_line - 1)
        finish = Math.min(lines.size, end_line)
        lines[start...finish].join
      end

      private def extract_file_docs(graph : Graph::CodeGraph) : Hash(String, String)
        docs = Hash(String, String).new
        graph.files.try &.each do |file_node|
          if doc = file_node.file_doc
            docs[file_node.path] = doc
          end
        end
        docs
      end

      private def cosine_similarity(a : Array(Float64), b : Array(Float64)) : Float64
        return 0.0 if a.size != b.size
        dot = 0.0
        norm_a = 0.0
        norm_b = 0.0
        a.size.times do |index|
          dot += a[index] * b[index]
          norm_a += a[index] * a[index]
          norm_b += b[index] * b[index]
        end
        return 0.0 if norm_a == 0.0 || norm_b == 0.0
        dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
      end
    end
  end
end
