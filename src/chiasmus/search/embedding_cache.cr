# Ported from vendor/chiasmus/src/search/embedding-cache.ts
#
# SHA-256-keyed embedding cache. Content-hash-keyed, tolerant of
# missing files, atomic saves. Keeps embeddings alive across runs
# so only changed content is re-embedded.

require "openssl"
require "json"

module Chiasmus
  module Search
    ECACHE_SCHEMA_VERSION = "1"

    record PartitionResult,
      cached : Hash(Int32, Array(Float64)),
      missing : Array(String),
      missing_indexes : Array(Int32)

    class EmbeddingCache
      @path : String
      @dim : Int32
      @by_hash : Hash(String, Array(Float64))
      @dirty : Bool
      @version : Int64
      @mutex : Mutex
      @before_dirty_clear_hook : Proc(Nil)?

      def initialize(@path : String, @dim : Int32)
        @by_hash = Hash(String, Array(Float64)).new
        @dirty = false
        @version = 0_i64
        @mutex = Mutex.new
        @before_dirty_clear_hook = nil
      end

      def self.hash(content : String) : String
        OpenSSL::Digest.new("SHA256").update(content).final.hexstring
      end

      def get(content : String) : Array(Float64)?
        @mutex.synchronize { @by_hash[EmbeddingCache.hash(content)]?.try(&.dup) }
      end

      def put(content : String, vector : Array(Float64)) : Nil
        unless vector.size == @dim
          raise ArgumentError.new(
            "EmbeddingCache: dimension mismatch — expected #{@dim}, got #{vector.size}"
          )
        end
        @mutex.synchronize do
          @by_hash[EmbeddingCache.hash(content)] = vector.dup
          @dirty = true
          @version += 1
        end
      end

      def put_many(contents : Array(String), vectors : Array(Array(Float64))) : Nil
        unless contents.size == vectors.size
          raise ArgumentError.new(
            "EmbeddingCache.put_many: length mismatch — #{contents.size} contents vs #{vectors.size} vectors"
          )
        end
        contents.zip(vectors) { |c, v| put(c, v) }
      end

      def partition_missing(contents : Array(String)) : PartitionResult
        @mutex.synchronize do
          cached = Hash(Int32, Array(Float64)).new
          missing = [] of String
          missing_indexes = [] of Int32

          contents.each_with_index do |content, i|
            hit = @by_hash[EmbeddingCache.hash(content)]?
            if hit
              cached[i] = hit.dup
            else
              missing << content
              missing_indexes << i
            end
          end

          PartitionResult.new(cached: cached, missing: missing, missing_indexes: missing_indexes)
        end
      end

      def save : Nil
        payload = nil.as(String?)
        snapshot_version = 0_i64

        @mutex.synchronize do
          return unless @dirty

          snapshot_version = @version
          payload = {
            "schemaVersion" => ECACHE_SCHEMA_VERSION,
            "dimension"     => @dim,
            "entries"       => @by_hash,
          }.to_json
        end

        dir = File.dirname(@path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        tmp = "#{@path}.tmp.#{Random::Secure.hex(8)}"
        File.write(tmp, payload || raise "expected payload")
        File.rename(tmp, @path)

        @before_dirty_clear_hook.try(&.call)

        @mutex.synchronize do
          @dirty = false if @version == snapshot_version
        end
      end

      def load : Nil
        raw = File.read(@path)
        parsed = JSON.parse(raw)
        return unless parsed["schemaVersion"]?.try(&.as_s) == ECACHE_SCHEMA_VERSION
        dim = parsed["dimension"]?.try(&.as_i)
        return unless dim == @dim

        entries = parsed["entries"]?.try(&.as_h)
        return unless entries

        loaded = Hash(String, Array(Float64)).new
        entries.each do |hash, vec_json|
          vec = vec_json.as_a.map(&.as_f)
          loaded[hash] = vec if vec.size == @dim
        end

        @mutex.synchronize do
          @by_hash = loaded
          @dirty = false
          @version = 0_i64
        end
      rescue File::NotFoundError
        # Tolerate missing cache file — first run.
      rescue JSON::ParseException
        # Tolerate corrupt cache file — invalidated.
      end

      def size : Int32
        @mutex.synchronize { @by_hash.size }
      end

      def set_before_dirty_clear_hook_for_test(&block : ->) : Nil
        @before_dirty_clear_hook = block
      end

      def clear_before_dirty_clear_hook_for_test : Nil
        @before_dirty_clear_hook = nil
      end
    end
  end
end
