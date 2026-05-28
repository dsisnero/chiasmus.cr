# Ported from vendor/chiasmus/src/search/vector-store.ts
#
# In-process vector store with linear-scan cosine search.
# Uses Crig's VectorDistance concepts (brute-force cosine, L2 norm caching)
# but implemented as a standalone class for raw pre-computed vector storage.

require "json"

module Chiasmus
  module Search
    SCHEMA_VERSION = "1"

    record VectorRecord,
      id : String,
      vector : Array(Float64),
      metadata : JSON::Any? = nil

    record VectorSearchHit,
      id : String,
      score : Float64,
      metadata : JSON::Any? = nil

    class DimensionError < Exception
      def initialize(expected : Int32, got : Int32)
        super("VectorStore: expected dimension #{expected}, got #{got}")
      end
    end

    class SchemaVersionError < Exception
      def initialize(got : String, expected : String)
        super("VectorStore: unsupported schema version #{got} (expected #{expected})")
      end
    end

    private struct InternalRow
      getter id : String
      getter vector : Array(Float64)
      getter norm : Float64
      getter metadata : JSON::Any?

      def initialize(@id : String, @vector : Array(Float64), @metadata : JSON::Any?)
        @norm = l2_norm(@vector)
      end

      private def l2_norm(v : Array(Float64)) : Float64
        Math.sqrt(v.sum { |x| x * x })
      end
    end

    class VectorStore
      private getter dim : Int32
      private getter by_id : Hash(String, InternalRow)

      def initialize(dimension : Int32)
        @dim = dimension
        @by_id = {} of String => InternalRow
      end

      def add(rec : VectorRecord) : Nil
        if rec.vector.size != @dim
          raise DimensionError.new(@dim, rec.vector.size)
        end
        @by_id[rec.id] = InternalRow.new(rec.id, rec.vector, rec.metadata)
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
        @by_id.keys
      end

      def search(query : Array(Float64), top_k : Int32) : Array(VectorSearchHit)
        if query.size != @dim
          raise DimensionError.new(@dim, query.size)
        end
        return [] of VectorSearchHit if @by_id.empty? || top_k <= 0

        q_norm = InternalRow.new("", query, nil).norm
        return [] of VectorSearchHit if q_norm == 0.0

        scored = [] of VectorSearchHit
        @by_id.each_value do |row|
          next if row.norm == 0.0
          dot = 0.0
          @dim.times do |i|
            dot += row.vector[i] * query[i]
          end
          score = dot / (row.norm * q_norm)
          scored << VectorSearchHit.new(id: row.id, score: score, metadata: row.metadata)
        end

        scored.sort_by! { |hit| -hit.score }
        scored.first(top_k)
      end

      def serialize : String
        vectors = @by_id.values.map do |row|
          obj = {
            "id"     => JSON::Any.new(row.id),
            "vector" => JSON::Any.new(row.vector.map { |v| JSON::Any.new(v) }),
          }
          if meta = row.metadata
            obj["metadata"] = meta
          end
          JSON::Any.new(obj)
        end

        JSON::Any.new({
          "schemaVersion" => JSON::Any.new(SCHEMA_VERSION),
          "dimension"     => JSON::Any.new(@dim.to_i64),
          "vectors"       => JSON::Any.new(vectors),
        }).to_json
      end

      def self.parse(raw : String) : VectorStore
        parsed = JSON.parse(raw)
        schema_version = parsed["schemaVersion"]?.try(&.as_s)
        if schema_version != SCHEMA_VERSION
          raise SchemaVersionError.new(schema_version || "(missing)", SCHEMA_VERSION)
        end
        dim = parsed["dimension"]?.try(&.as_i)
        raise SchemaVersionError.new("(missing dimension)", SCHEMA_VERSION) unless dim

        store = VectorStore.new(dimension: dim.to_i32)
        parsed["vectors"]?.try(&.as_a).try &.each do |v|
          arr = v["vector"].as_a.map(&.as_f)
          meta = v["metadata"]?
          store.add(VectorRecord.new(
            id: v["id"].as_s,
            vector: arr,
            metadata: meta,
          ))
        end
        store
      end
    end
  end
end
