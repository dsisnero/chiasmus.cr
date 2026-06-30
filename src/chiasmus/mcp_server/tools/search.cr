# chiasmus_search tool — Semantic code search over files
require "mcp"
require "crig"
require "../types"
require "../tool_schemas"
require "../../search/engine"
require "../../search/embedding_cache"
require "../../graph/extractor"
require "../../utils/config"
require "../../utils/bounded_work"

module Chiasmus
  module MCPServer
    module Tools
      class SearchTool
        MAX_FILE_SIZE          = 500_000
        DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT

        private record SearchReadResult,
          path : String,
          content : String? = nil,
          warning : String? = nil

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SearchInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'query' (non-empty string) is required") if args.query.strip.empty?
          return Types::ErrorResponse.new("'files' (non-empty array of absolute paths) is required") if args.files.empty?

          top_k = {1, {args.top_k, 100}.min}.max

          file_contents, warnings = read_search_files(args.files)

          if file_contents.empty?
            return Types::ErrorResponse.new("No readable files in `files`. Warnings: #{warnings.join("; ")}") unless warnings.empty?
            return Types::ErrorResponse.new("No readable files in `files`.")
          end

          source_files = file_contents.map { |path, content| Graph::SourceFile.new(path: path, content: content) }
          graph = Graph::Extractor.extract_graph_async(source_files).receive

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

        private def read_search_files(files : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT) : {Hash(String, String), Array(String)}
          read_search_files(files, max_concurrent) { |path| File.read(path) }
        end

        private def read_search_files(files : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String) : {Hash(String, String), Array(String)}
          file_contents = Hash(String, String).new
          warnings = [] of String

          results = Utils::BoundedWork.map_ordered(files, max_concurrent) do |path|
            begin
              st = File.info(path)
              if !st.file?
                SearchReadResult.new(path: path, warning: "skip (not a file): #{path}")
              elsif st.size > MAX_FILE_SIZE
                SearchReadResult.new(path: path, warning: "skip (over #{MAX_FILE_SIZE} bytes): #{path}")
              else
                SearchReadResult.new(path: path, content: reader.call(path))
              end
            rescue ex
              SearchReadResult.new(path: path, warning: "read failed: #{path} — #{ex.message}")
            end
          end

          results.compact_map(&.itself).each do |result|
            if warning = result.warning
              warnings << warning
            elsif content = result.content
              file_contents[result.path] = content
            end
          end

          {file_contents, warnings}
        end

        # Resolve embedding model from environment.
        # Provider priority: CHIASMUS_EMBED_PROVIDER > env-backed fallback > implicit ollama.
        # Supports: ollama, deepseek, openai.
        # Ollama defaults to nomic-embed-text, others to text-embedding-3-small.
        private def resolve_embedding_model
          provider = ENV["CHIASMUS_EMBED_PROVIDER"]?
          base_url = ENV["CHIASMUS_EMBED_URL"]?

          if provider
            case provider
            when "ollama"
              return self.class.ollama_embedding_model(base_url)
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

            return nil
          end

          resolve_embedding_model_fallback(base_url) || self.class.ollama_embedding_model(base_url)
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

        def self.embedding_configured? : Bool
          provider = ENV["CHIASMUS_EMBED_PROVIDER"]?

          case provider
          when "ollama"
            true
          when "deepseek"
            configured?(ENV["DEEPSEEK_API_KEY"]?)
          when "openai"
            configured?(ENV["OPENAI_API_KEY"]?)
          when nil
            false
          else
            false
          end
        end

        private def self.configured?(value : String?) : Bool
          !value.nil? && !value.blank?
        end

        def self.ollama_embedding_model(base_url : String?)
          model_name = ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT
          url = base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL
          client = Crig::Providers::Ollama::Client.new(Crig::Nothing.new, url)
          client.embedding_model(model_name)
        end

        def self.tool_name : String
          "chiasmus_search"
        end

        def self.tool_description : String
          <<-DESC
          Semantic code search over a set of files. Finds functions and methods
          whose meaning matches a natural-language query.

          Dedicated walkers: Crystal, TypeScript, JavaScript, Python, Go, Rust, Java,
          C#, C++, C, Kotlin, Scala, Dart, PHP, Perl, Bash, Protobuf, Clojure.
          Generic tree-sitter fallback for 35+ additional languages.

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

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"hits":{"type":"array"}})).as_h
          )
        end
      end
    end
  end
end
