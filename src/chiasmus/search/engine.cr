# Ported from vendor/chiasmus/src/search/engine.ts
#
# Search engine: build an embedding corpus from a CodeGraph + source,
# run a semantic query via a pluggable embedding adapter (Crig::EmbeddingModelDyn),
# return top-K hits.

require "../graph/types"
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
      signature : String?,
      leading_doc : String?,
      text : String

    record SearchHit,
      id : String,
      name : String,
      file : String,
      line : Int32,
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

        graph.defines.each do |d|
          next unless d.kind.function? || d.kind.method?
          content = files[d.file]?
          next unless content

          snippet = snippet_around(content, d.line)
          parts = [d.name] of String
          if doc = file_doc[d.file]?
            parts << doc
          end
          parts << snippet
          text = parts.join("\n")[0, MAX_TEXT_LEN]

          out << SearchCorpusEntry.new(
            id: make_entry_id(d),
            name: d.name,
            file: d.file,
            line: d.line,
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
        model : Crig::EmbeddingModelDyn,
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

        scored.sort_by! { |s, _| -s }
        scored.first(top_k).compact_map do |score, i|
          e = corpus[i]?
          next unless e
          SearchHit.new(
            id: e.id,
            name: e.name,
            file: e.file,
            line: e.line,
            signature: e.signature,
            leading_doc: e.leading_doc,
            score: score,
          )
        end
      end

      private def make_entry_id(d : Graph::DefinesFact) : String
        "#{d.file}##{d.name}##{d.line}"
      end

      private def snippet_around(source : String, start_line : Int32) : String
        lines = source.lines
        start = Math.max(0, start_line - 1)
        finish = Math.min(lines.size, start + SNIPPET_LINES)
        lines[start...finish].join
      end

      private def extract_file_docs(graph : Graph::CodeGraph) : Hash(String, String)
        Hash(String, String).new
      end

      private def cosine_similarity(a : Array(Float64), b : Array(Float64)) : Float64
        return 0.0 if a.size != b.size
        dot = 0.0
        norm_a = 0.0
        norm_b = 0.0
        a.size.times do |i|
          dot += a[i] * b[i]
          norm_a += a[i] * a[i]
          norm_b += b[i] * b[i]
        end
        return 0.0 if norm_a == 0.0 || norm_b == 0.0
        dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
      end
    end
  end
end
