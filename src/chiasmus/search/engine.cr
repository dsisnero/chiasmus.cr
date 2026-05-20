# Ported from vendor/chiasmus/src/search/engine.ts
#
# Search engine: build an embedding corpus from a CodeGraph + source,
# run a semantic query via a pluggable embedding adapter, return top-K
# hits. Linear-scan vector store; fine for repos under ~10k callable defines.

require "../graph/types"
require "./vector_store"
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

    # Minimal embedding adapter interface — callers supply a proc.
    # dimension(): returns vector dimension
    # embed(texts): returns Array(Array(Float64)) — one vector per text
    module EmbeddingAdapter
      abstract def dimension : Int32
      abstract def embed(texts : Array(String)) : Array(Array(Float64))
    end

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
          if signature = d.responds_to?(:signature)
            parts << d.signature
          end
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

      def run_search(
        query : String,
        corpus : Array(SearchCorpusEntry),
        adapter : EmbeddingAdapter,
        top_k : Int32,
        cache : EmbeddingCache? = nil,
      ) : Array(SearchHit)
        return [] of SearchHit if corpus.empty?

        dim = adapter.dimension
        store = VectorStore.new(dim)

        to_embed = [] of String
        to_embed_idx = [] of Int32
        cached_vecs = Hash(Int32, Array(Float64)).new

        corpus.each_with_index do |entry, i|
          hit = cache.try(&.get(entry.text))
          if hit && hit.size == dim
            cached_vecs[i] = hit
          else
            to_embed << entry.text
            to_embed_idx << i
          end
        end

        unless to_embed.empty?
          fresh = adapter.embed(to_embed)
          fresh.each_with_index do |vec, j|
            idx = to_embed_idx[j]
            cached_vecs[idx] = vec
            cache.try(&.put(to_embed[j], vec))
          end
        end

        corpus.each_with_index do |entry, i|
          vec = cached_vecs[i]?
          next unless vec
          store.add(VectorRecord.new(id: entry.id, vector: vec, metadata: nil))
        end

        query_vec = adapter.embed([query])[0]
        hits = store.search(query_vec, top_k)

        by_id = Hash(String, SearchCorpusEntry).new
        corpus.each { |e| by_id[e.id] = e }

        hits.compact_map do |h|
          e = by_id[h.id]?
          next unless e
          SearchHit.new(
            id: h.id,
            name: e.name,
            file: e.file,
            line: e.line,
            signature: e.signature,
            leading_doc: e.leading_doc,
            score: h.score,
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
        # CodeGraph files carry fileDoc — extract into a lookup map
        # If graph.files isn't populated, return empty
        Hash(String, String).new
      end
    end
  end
end
