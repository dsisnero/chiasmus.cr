# chiasmus_search tool — Semantic code search over files
require "mcp"
require "../types"
require "../tool_schemas"
require "../../search/engine"
require "../../search/embedding_cache"
require "../../graph/extractor"

module Chiasmus
  module MCPServer
    module Tools
      class SearchTool
        MAX_FILE_SIZE = 500_000

        private def error_response(message : String) : Hash(String, JSON::Any)
          JSON.parse(Types::ErrorResponse.new(message).to_json).as_h
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          query = arguments["query"]?.try(&.as_s?)
          files = arguments["files"]?.try(&.as_a?.try(&.map(&.as_s)))
          top_k = arguments["top_k"]?.try(&.as_i?) || 10

          return error_response("'query' (non-empty string) is required") unless query && !query.strip.empty?
          return error_response("'files' (non-empty array of absolute paths) is required") unless files && !files.empty?

          top_k = {1, {top_k, 100}.min}.max

          # Read files
          file_contents = Hash(String, String).new
          warnings = [] of String

          files.each do |p|
            begin
              st = File.info(p)
              unless st.file?
                warnings << "skip (not a file): #{p}"
                next
              end
              if st.size > MAX_FILE_SIZE
                warnings << "skip (over #{MAX_FILE_SIZE} bytes): #{p}"
                next
              end
              file_contents[p] = File.read(p)
            rescue ex
              warnings << "read failed: #{p} — #{ex.message}"
            end
          end

          if file_contents.empty?
            result = {"error" => JSON::Any.new("No readable files in `files`.")} of String => JSON::Any
            result["warnings"] = JSON::Any.new(warnings) unless warnings.empty?
            return result
          end

          # Extract graph
          source_files = file_contents.map { |p, c| Graph::SourceFile.new(path: p, content: c) }
          graph = Graph::Extractor.extract_graph(source_files)

          # Build corpus
          corpus = Search::SearchEngine.build_search_corpus(graph, file_contents)

          if corpus.empty?
            result = {"hits" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any
            result["warnings"] = JSON::Any.new(warnings) unless warnings.empty?
            return result
          end

          # Get embedding model from Crig (configured via env)
          model = resolve_embedding_model
          unless model
            return error_response(
              "No embedding provider configured. " +
              "Set OPENAI_API_KEY / DEEPSEEK_API_KEY / OPENROUTER_API_KEY " +
              "(see CHIASMUS_EMBED_* env vars for overrides)."
            )
          end

          # Cache
          home = MCPServer::Server.chiasmus_home
          dim = model.ndims
          cache_path = File.join(home, "embeddings", "d#{dim}.json")
          cache = Search::EmbeddingCache.new(cache_path, dim)
          begin
            cache.load
          rescue
          end

          # Search
          hits = Search::SearchEngine.run_search(query.strip, corpus, model, top_k, cache)

          # Save cache
          begin
            cache.save
          rescue
          end

          result = hits.map do |h|
            {
              "name"  => JSON::Any.new(h.name),
              "file"  => JSON::Any.new(h.file),
              "line"  => JSON::Any.new(h.line.to_i64),
              "score" => JSON::Any.new(h.score),
            }
          end

          {
            "hits" => JSON::Any.new(result),
          }
        rescue ex
          error_response(ex.message || ex.class.name)
        end

        # Resolve embedding model from environment
        private def resolve_embedding_model : Crig::EmbeddingModelDyn?
          model_name = ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small"

          if api_key = ENV["OPENAI_API_KEY"]?
            client = Crig::Providers::OpenAI::Client.new(api_key)
            return client.embedding_model(model_name)
          end

          if api_key = ENV["DEEPSEEK_API_KEY"]?
            client = Crig::Providers::OpenAI::Client.new(
              api_key,
              "https://api.deepseek.com/v1",
            )
            return client.embedding_model(model_name)
          end

          nil
        end

        def self.tool_name : String
          "chiasmus_search"
        end

        def self.tool_description : String
          <<-DESC
          Semantic code search over a set of files. Finds functions and methods
          whose meaning matches a natural-language query.

          Uses embeddings + cosine similarity. Returns a ranked list of
          {name, file, line, score}. Ranking is by closeness of the concept,
          NOT by exact name match.

          Requires an embedding provider configured via env:
            OPENAI_API_KEY  → OpenAI text-embedding-3-small
            DEEPSEEK_API_KEY → DeepSeek (OpenAI-compatible)
            CHIASMUS_EMBED_MODEL → override default model

          Caches embeddings by content SHA-256 — unchanged code is not re-embedded.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "query" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Natural language query for semantic search"),
              },
              "files" => ToolSchemas::Common.files_property,
              "top_k" => {
                "type"        => JSON::Any.new("number"),
                "description" => JSON::Any.new("Number of results (1–100, default 10)"),
              },
            },
            required: ["query", "files"]
          ).to_mcp_input
        end
      end
    end
  end
end
