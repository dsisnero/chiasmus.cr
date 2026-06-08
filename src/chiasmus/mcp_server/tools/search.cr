# chiasmus_search tool — Semantic code search over files
require "mcp"
require "crig"
require "../types"
require "../tool_schemas"
require "../../search/engine"
require "../../search/embedding_cache"
require "../../graph/extractor"
require "../../utils/config"

module Chiasmus
  module MCPServer
    module Tools
      class SearchTool
        MAX_FILE_SIZE = 500_000

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SearchInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'query' (non-empty string) is required") if args.query.strip.empty?
          return Types::ErrorResponse.new("'files' (non-empty array of absolute paths) is required") if args.files.empty?

          top_k = {1, {args.top_k, 100}.min}.max

          file_contents = Hash(String, String).new
          warnings = [] of String

          args.files.each do |path|
            begin
              st = File.info(path)
              unless st.file?
                warnings << "skip (not a file): #{path}"
                next
              end
              if st.size > MAX_FILE_SIZE
                warnings << "skip (over #{MAX_FILE_SIZE} bytes): #{path}"
                next
              end
              file_contents[path] = File.read(path)
            rescue ex
              warnings << "read failed: #{path} — #{ex.message}"
            end
          end

          if file_contents.empty?
            return Types::ErrorResponse.new("No readable files in `files`. Warnings: #{warnings.join("; ")}") unless warnings.empty?
            return Types::ErrorResponse.new("No readable files in `files`.")
          end

          source_files = file_contents.map { |path, content| Graph::SourceFile.new(path: path, content: content) }
          graph = Graph::Extractor.extract_graph(source_files)

          corpus = Search::SearchEngine.build_search_corpus(graph, file_contents)

          if corpus.empty?
            return Types::ErrorResponse.new("No searchable content found in files.")
          end

          model = resolve_embedding_model
          unless model
            return Types::ErrorResponse.new(
              "No embedding provider configured. " +
              "Set OPENAI_API_KEY / DEEPSEEK_API_KEY / OPENROUTER_API_KEY " +
              "(see CHIASMUS_EMBED_* env vars for overrides)."
            )
          end

          home = Utils::Config.chiasmus_home
          dim = model.ndims
          cache_path = File.join(home, "embeddings", "d#{dim}.json")
          cache = Search::EmbeddingCache.new(cache_path, dim)
          begin
            cache.load
          rescue
          end

          hits = Search::SearchEngine.run_search(args.query.strip, corpus, model, top_k, cache)

          begin
            cache.save
          rescue
          end

          result = hits.map do |hit|
            Types::SearchHitJSON.new(
              name: hit.name,
              file: hit.file,
              line: hit.line,
              score: hit.score
            )
          end

          Types::SearchResponse.new(hits: result, warnings: warnings.empty? ? nil : warnings)
        rescue ex
          Types::ErrorResponse.new("#{ex.class}: #{ex.message || "(no message)"}")
        end

        # Resolve embedding model from environment.
        # Provider priority: CHIASMUS_EMBED_PROVIDER > DEEPSEEK_API_KEY > OPENAI_API_KEY.
        # Supports: ollama, deepseek, openai.
        # Ollama defaults to nomic-embed-text, others to text-embedding-3-small.
        private def resolve_embedding_model
          provider = ENV["CHIASMUS_EMBED_PROVIDER"]? || "deepseek"
          base_url = ENV["CHIASMUS_EMBED_URL"]?

          case provider
          when "ollama"
            model_name = ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT
            url = base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL
            client = Crig::Providers::Ollama::Client.new(Crig::Nothing.new, url)
            return client.embedding_model(model_name)
          when "deepseek"
            model_name = ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small"
            if api_key = ENV["DEEPSEEK_API_KEY"]?
              url = base_url || "https://api.deepseek.com/v1"
              client = Crig::Providers::OpenAI::Client.new(api_key, url)
              return client.embedding_model(model_name)
            end
          when "openai"
            model_name = ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small"
            if api_key = ENV["OPENAI_API_KEY"]?
              client = Crig::Providers::OpenAI::Client.new(api_key)
              return client.embedding_model(model_name)
            end
          end

          resolve_embedding_model_fallback(base_url)
        end

        private def resolve_embedding_model_fallback(base_url : String?)
          model = ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small"

          if api_key = ENV["DEEPSEEK_API_KEY"]?
            url = base_url || "https://api.deepseek.com/v1"
            client = Crig::Providers::OpenAI::Client.new(api_key, url)
            return client.embedding_model(model)
          end

          if api_key = ENV["OPENAI_API_KEY"]?
            client = Crig::Providers::OpenAI::Client.new(api_key)
            return client.embedding_model(model)
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
              "query"     => ToolSchemas::SchemaProperty.new("string", "Natural language query for semantic search"),
              "files"     => ToolSchemas::Common.files_property,
              "top_k"     => ToolSchemas::SchemaProperty.new("number", "Number of results (1–100, default 10)"),
              "languages" => ToolSchemas::ArraySchemaProperty.new("Filter by language(s) — e.g. [\"go\", \"rust\"]. Uses Discovery pipeline with broader language support when specified."),
              "kinds"     => ToolSchemas::ArraySchemaProperty.new("Filter by symbol kind(s) — e.g. [\"class\", \"interface\"]. Requires languages param."),
            },
            required: ["query", "files"]
          ).to_mcp_input
        end
      end
    end
  end
end
