# Ported from vendor/chiasmus/src/search/vector-store.ts
#
# In-process vector store with linear-scan cosine search.
# Correct up to ~10k vectors; switch to an HNSW backing if the corpus
# grows substantially. Serializable as JSON for on-disk persistence.

require "json"

module Chiasmus
  module Search
    SCHEMA_VERSION = "1"

    record VectorRecord,
      id : String,
      vector : Array(Float64),
      metadata : JSON::Any?

    record VectorSearchHit,
      id : String,
      score : Float64,
      metadata : JSON::Any?

    class VectorStore
      record InternalRow,
        id : String,
        vector : Array(Float64),
        norm : Float64,
        metadata : JSON::Any?

      @dim : Int32
      @by_id : Hash(String, InternalRow)

      def initialize(@dim : Int32)
        @by_id = Hash(String, InternalRow).new
      end

      def add(rec : VectorRecord) : Nil
        if rec.vector.size != @dim
          raise ArgumentError.new(
            "VectorStore: expected dimension #{@dim}, got #{rec.vector.size}"
          )
        end
        norm = l2_norm(rec.vector)
        @by_id[rec.id] = InternalRow.new(
          id: rec.id,
          vector: rec.vector,
          norm: norm,
          metadata: rec.metadata,
        )
      end

      def remove(id : String) : Bool
        !@by_id.delete(id).nil?
      end

      def has?(id : String) : Bool
        @by_id.has_key?(id)
      end

      def size : Int32
        @by_id.size
      end

      def ids : Array(String)
        @by_id.keys.to_a
      end

      def search(query : Array(Float64), top_k : Int32) : Array(VectorSearchHit)
        if query.size != @dim
          raise ArgumentError.new(
            "VectorStore: query dimension #{query.size} != store dimension #{@dim}"
          )
        end
        return [] of VectorSearchHit if @by_id.empty? || top_k <= 0

        q_norm = l2_norm(query)
        return [] of VectorSearchHit if q_norm == 0.0

        scored = [] of VectorSearchHit
        @by_id.each_value do |row|
          next if row.norm == 0.0
          dot = 0.0
          @dim.times { |i| dot += row.vector[i] * query[i] }
          score = dot / (row.norm * q_norm)
          scored << VectorSearchHit.new(id: row.id, score: score, metadata: row.metadata)
        end

        scored.sort_by! { |h| -h.score }
        scored.first(top_k)
      end

      def serialize : String
        vectors = [] of NamedTuple(id: String, vector: Array(Float64), metadata: JSON::Any?)
        @by_id.each_value do |row|
          vectors << {id: row.id, vector: row.vector, metadata: row.metadata}
        end
        {
          "schemaVersion" => SCHEMA_VERSION,
          "dimension"     => @dim,
          "vectors"       => vectors,
        }.to_json
      end

      def self.parse(raw : String) : VectorStore
        parsed = JSON.parse(raw)
        schema = parsed["schemaVersion"]?.try(&.as_s)
        unless schema == SCHEMA_VERSION
          raise ArgumentError.new(
            "VectorStore: unsupported schema version #{schema} (expected #{SCHEMA_VERSION})"
          )
        end
        dim = parsed["dimension"].as_i
        store = VectorStore.new(dim)
        parsed["vectors"].as_a.each do |v|
          id = v["id"].as_s
          vector = v["vector"].as_a.map(&.as_f)
          metadata = v["metadata"]?
          store.add(VectorRecord.new(id: id, vector: vector, metadata: metadata))
        end
        store
      end

      private def l2_norm(v : Array(Float64)) : Float64
        sum = 0.0
        v.each { |x| sum += x * x }
        Math.sqrt(sum)
      end
    end
  end
end
