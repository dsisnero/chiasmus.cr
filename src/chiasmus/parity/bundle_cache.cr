require "json"
require "openssl"
require "../graph/cache"

module Chiasmus
  module Parity
    # Content-addressed cache for the complete parity bundle projection.
    module BundleCache
      extend self

      VERSION            = "parity-bundle-v1"
      MAX_BUNDLE_BYTES   = 8 * 1024 * 1024
      REQUIRED_ARTIFACTS = ["maps.tsv", "surfaces.tsv", "maps.pl", "port-concepts.jsonl"]
      OPTIONAL_ARTIFACTS = ["divergences.tsv"]
      ALLOWED_ARTIFACTS  = REQUIRED_ARTIFACTS + OPTIONAL_ARTIFACTS

      def load(cache_dir : String, input_paths : Array(String?), content_fingerprint : String? = nil) : Hash(String, String)?
        content = content_fingerprint || fingerprint(input_paths)
        cached = Graph::GraphCache.fetch_extraction_payload(
          cache_path(input_paths), content, "parity-bundle", VERSION, cache_dir
        )
        return nil unless cached

        artifacts = Hash(String, String).from_json(cached[:payload])
        return nil unless REQUIRED_ARTIFACTS.all? { |name| artifacts.has_key?(name) }
        return nil unless artifacts.keys.all? { |name| ALLOWED_ARTIFACTS.includes?(name) }
        artifacts
      rescue JSON::ParseException
        nil
      end

      def save(cache_dir : String, input_paths : Array(String?), artifacts : Hash(String, String), content_fingerprint : String? = nil) : Nil
        payload = artifacts.to_json
        return if payload.bytesize > MAX_BUNDLE_BYTES

        content = content_fingerprint || fingerprint(input_paths)
        Graph::GraphCache.save_extraction_payload(
          cache_path(input_paths), content, "parity-bundle", VERSION, payload, cache_dir
        )
      end

      private def cache_path(input_paths : Array(String?)) : String
        input_paths.first? || "parity-bundle"
      end

      # Hash every input's current bytes and path; callers can compare before
      # and after rendering to avoid caching a result across an in-flight edit.
      def fingerprint(input_paths : Array(String?)) : String
        input_paths.map do |path|
          next {path: nil, digest: nil} unless path
          digest = if File.file?(path)
                     OpenSSL::Digest.new("SHA256").file(path).final.hexstring
                   else
                     nil
                   end
          {path: File.expand_path(path), digest: digest}
        end.to_json
      end
    end
  end
end
