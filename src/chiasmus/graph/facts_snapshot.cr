require "json"
require "openssl"
require "./cache"

module Chiasmus
  module Graph
    module FactsSnapshot
      extend self

      PREFIX = "% graph_snapshot "

      record Metadata,
        cache_dir : String,
        repo_key : String,
        snapshot : String

      def snapshot_name(
        language : String,
        dir : String,
        entry_points : Array(String),
        include_insights : Bool,
      ) : String
        digest = OpenSSL::Digest.new("SHA256")
          .update(language)
          .update("\u0000")
          .update(File.expand_path(dir))
          .update("\u0000")
          .update(entry_points.join(","))
          .update("\u0000")
          .update(include_insights ? "1" : "0")
          .final
          .hexstring
        "facts-#{digest[0, 24]}"
      end

      def metadata_line(metadata : Metadata) : String
        "#{PREFIX}#{{
                      "cache_dir" => metadata.cache_dir,
                      "repo_key"  => metadata.repo_key,
                      "snapshot"  => metadata.snapshot,
                    }.to_json}"
      end

      def parse_metadata_line?(line : String) : Metadata?
        stripped = line.strip
        return nil unless stripped.starts_with?(PREFIX)

        payload = JSON.parse(stripped[PREFIX.size..]).as_h
        cache_dir = payload["cache_dir"]?.try(&.as_s) || return nil
        repo_key = payload["repo_key"]?.try(&.as_s) || return nil
        snapshot = payload["snapshot"]?.try(&.as_s) || return nil
        Metadata.new(cache_dir: cache_dir, repo_key: repo_key, snapshot: snapshot)
      rescue
        nil
      end

      def load_graph_from_facts(path : String) : CodeGraph?
        metadata = nil.as(Metadata?)
        File.each_line(path) do |line|
          metadata = parse_metadata_line?(line)
          break if metadata
        end

        return nil unless metadata
        GraphCache.load_snapshot(metadata.snapshot, metadata.cache_dir, repo_key: metadata.repo_key)
      rescue
        nil
      end
    end
  end
end
