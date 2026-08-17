# chiasmus_search tool — Semantic code search over files
require "mcp"
require "crig"
require "../types"
require "../tool_schemas"
require "../../search/engine"
require "../../search/embedding_cache"
require "./indexed_graph_loader"
require "../../graph/extractor"
require "../../utils/config"
require "../../utils/bounded_work"
require "tracing"

module Chiasmus
  module MCPServer
    module Tools
      class SearchTool
        MAX_FILE_SIZE          = 500_000
        DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT

        record EmbeddingResolution,
          provider : String,
          model_name : String,
          api_key : String? = nil,
          base_url : String? = nil

        private record SearchReadResult,
          path : String,
          content : String? = nil,
          warning : String? = nil

        def initialize(@project_index : Index::ProjectIndex? = nil)
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SearchInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'query' (non-empty string) is required") if args.query.strip.empty?
          return Types::ErrorResponse.new("'files' (non-empty array of absolute paths) is required") if args.files.empty?
          if error = self.class.local_embedding_configuration_error
            return Types::ErrorResponse.new(error)
          end

          top_k = {1, {args.top_k, 100}.min}.max

          file_contents, warnings = read_search_files(args.files)

          if error = validate_search_files(file_contents, warnings)
            return error
          end

          source_files = file_contents.map { |path, content| Graph::SourceFile.new(path: path, content: content) }
          graph = load_search_graph(source_files) || return Types::ErrorResponse.new("Unable to index all requested files")

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
              line_end: hit.line_end,
              score: hit.score
            )
          end

          Types::SearchResponse.new(hits: result, warnings: warnings.empty? ? nil : warnings)
        rescue ex
          Types::ErrorResponse.new("#{ex.class}: #{ex.message || "(no message)"}")
        end

        private def validate_search_files(file_contents : Hash(String, String), warnings : Array(String)) : Types::ErrorResponse?
          return nil unless file_contents.empty?
          return Types::ErrorResponse.new("No readable files in `files`. Warnings: #{warnings.join("; ")}") unless warnings.empty?
          Types::ErrorResponse.new("No readable files in `files`.")
        end

        private def load_search_graph(source_files : Array(Graph::SourceFile)) : Graph::CodeGraph?
          IndexedGraphLoader.load_graph(
            source_files.map(&.path),
            Graph::GraphCache.default_cache_dir,
            @project_index,
            "chiasmus.search.cache"
          )
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
          resolution = self.class.resolve_embedding_resolution
          return nil unless resolution

          case resolution.provider
          when "ollama"
            self.class.ollama_embedding_model(resolution.base_url, resolution.model_name)
          when "deepseek"
            api_key = resolution.api_key || return nil
            client = Crig::Providers::OpenAI::Client.new(api_key, resolution.base_url || "https://api.deepseek.com/v1")
            client.embedding_model(resolution.model_name)
          when "openai"
            api_key = resolution.api_key || return nil
            client = Crig::Providers::OpenAI::Client.new(api_key)
            client.embedding_model(resolution.model_name)
          else
            nil
          end
        end

        def self.resolve_embedding_resolution : EmbeddingResolution?
          resolve_embedding_resolution(Utils::Config.load)
        end

        # Crystal uses an Ollama endpoint for configured local embeddings.
        # The upstream node-llama-cpp-only fields remain diagnostic-only.
        def self.resolve_embedding_resolution(config : Utils::Config::ChiasmusConfig) : EmbeddingResolution?
          provider = ENV["CHIASMUS_EMBED_PROVIDER"]?
          base_url = ENV["CHIASMUS_EMBED_URL"]?

          if local = config.local_embeddings
            if local.enabled? && (model = local.model) && !model.blank?
              return EmbeddingResolution.new(
                provider: "ollama",
                model_name: model,
                base_url: base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL,
              )
            end
          end

          if provider
            case provider
            when "ollama"
              return EmbeddingResolution.new(
                provider: "ollama",
                model_name: ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT,
                base_url: base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL,
              )
            when "deepseek"
              if api_key = ENV["DEEPSEEK_API_KEY"]?
                return EmbeddingResolution.new(
                  provider: "deepseek",
                  model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
                  api_key: api_key,
                  base_url: base_url || "https://api.deepseek.com/v1",
                )
              end
            when "openai"
              if api_key = ENV["OPENAI_API_KEY"]?
                return EmbeddingResolution.new(
                  provider: "openai",
                  model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
                  api_key: api_key,
                )
              end
            end

            return nil
          end

          if api_key = ENV["DEEPSEEK_API_KEY"]?
            return EmbeddingResolution.new(
              provider: "deepseek",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
              api_key: api_key,
              base_url: base_url || "https://api.deepseek.com/v1",
            )
          end

          if api_key = ENV["OPENAI_API_KEY"]?
            return EmbeddingResolution.new(
              provider: "openai",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
              api_key: api_key,
            )
          end

          EmbeddingResolution.new(
            provider: "ollama",
            model_name: ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT,
            base_url: base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL,
          )
        end

        # node-llama-cpp is a Node-only optional backend. Crystal supports
        # local semantic search through an Ollama embedding endpoint instead.
        def self.local_embedding_configuration_error : String?
          local_embedding_configuration_error(Utils::Config.load)
        end

        def self.local_embedding_configuration_error(_config : Utils::Config::ChiasmusConfig) : String?
          return nil unless ENV["CHIASMUS_LOCAL_EMBED"]?

          "Local embeddings (CHIASMUS_LOCAL_EMBED/localEmbeddings) are not supported by the Crystal build; " +
            "use CHIASMUS_EMBED_PROVIDER=ollama with a local Ollama embedding model instead."
        end

        def self.resolved_embedding_provider_name : String?
          resolve_embedding_resolution.try(&.provider)
        end

        def self.resolved_embedding_model_name : String?
          resolve_embedding_resolution.try(&.model_name)
        end

        def self.embedding_configured? : Bool
          embedding_configured?(Utils::Config.load)
        end

        def self.embedding_configured?(config : Utils::Config::ChiasmusConfig) : Bool
          if local = config.local_embeddings
            return true if local.enabled? && local.model.try { |model| !model.blank? }
          end

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

        def self.ollama_embedding_model(base_url : String?, model_name : String? = nil)
          model_name ||= ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT
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
          {name, file, line, line_end, score}. Ranking is by closeness of the concept,
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
