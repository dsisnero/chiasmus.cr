# chiasmus_search tool — Semantic code search over files
require "mcp"
require "crig"
require "openssl"
require "http/client"
require "../types"
require "../tool_schemas"
require "../../search/engine"
require "../../search/embedding_cache"
require "./indexed_graph_loader"
require "../../graph/extractor"
require "../../utils/config"
require "../../utils/bounded_work"
require "tracing"
require "../../index/file_discovery"

module Chiasmus
  module MCPServer
    module Tools
      class SearchTool
        MAX_FILE_SIZE             = 500_000
        MAX_SEARCH_FILES          =     500
        MAX_SEARCH_BYTES          = 25 * 1024 * 1024
        DEFAULT_MAX_CONCURRENT    = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT
        OLLAMA_PROBE_TIMEOUT      = 1.second
        SUPPORTED_EMBED_PROVIDERS = %w[ollama openai openrouter deepseek]

        record EmbeddingResolution,
          provider : String,
          model_name : String,
          api_key : String? = nil,
          base_url : String? = nil

        private record SearchReadResult,
          path : String,
          content : String? = nil,
          warning : String? = nil

        def initialize(
          @project_index : Index::ProjectIndex? = nil,
          @config : Utils::Config::ChiasmusConfig = Utils::Config.load,
          @chiasmus_home : String = Utils::Config.chiasmus_home,
        )
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          if error = self.class.validate_arguments(arguments)
            return Types::ErrorResponse.new(error)
          end

          args = Types::SearchInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'query' (non-empty string) is required") if args.query.strip.empty?
          if error = self.class.local_embedding_configuration_error(@config)
            return Types::ErrorResponse.new(error)
          end

          top_k = {1, {args.top_k, 100}.min}.max

          search_files = if directory = args.directory
                           directory_search_files(directory, args.include_patterns)
                         else
                           args.files || [] of String
                         end
          file_contents, warnings = read_search_files(search_files)

          if error = validate_search_files(file_contents, warnings, args.directory ? "directory" : "files")
            return error
          end

          source_files = file_contents.map { |path, content| Graph::SourceFile.new(path: path, content: content) }
          graph = load_search_graph(source_files) || return Types::ErrorResponse.new("Unable to index all requested files")

          corpus = Search::SearchEngine.build_search_corpus(graph, file_contents)

          if corpus.empty?
            return Types::SearchResponse.new([] of Types::SearchHitJSON, warnings: warnings.empty? ? nil : warnings, searched_files: file_contents.size)
          end

          resolution = self.class.resolve_embedding_resolution(@config) ||
                       return Types::ErrorResponse.new(
                         self.class.embedding_configuration_error(@config) || "No embedding provider configured."
                       )
          model = resolve_embedding_model(resolution) ||
                  return Types::ErrorResponse.new("Unable to create embedding model for #{resolution.provider}")

          dim = model.ndims
          cache_path = self.class.embedding_cache_path(@chiasmus_home, resolution, dim)
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

          Types::SearchResponse.new(hits: result, warnings: warnings.empty? ? nil : warnings, searched_files: file_contents.size)
        rescue ex
          Types::ErrorResponse.new("#{ex.class}: #{ex.message || "(no message)"}")
        end

        def self.validate_arguments(arguments : Hash(String, JSON::Any)) : String?
          query = arguments["query"]?.try(&.as_s?)
          return "'query' (non-empty string) is required" unless query
          return "'query' (non-empty string) is required" if query.strip.empty?

          files = arguments["files"]?
          directory = arguments["directory"]?
          return "Exactly one of 'files' or 'directory' is required" if files.nil? == directory.nil?
          if files
            array = files.as_a?
            return "'files' (non-empty array of absolute paths) is required" if array.nil? || array.empty? || array.any? { |file| file.as_s?.nil? }
          end
          if directory
            path = directory.as_s?
            return "'directory' must be an absolute directory path" unless path && path.starts_with?('/')
            return "'directory' must exist and be a directory" unless File.directory?(path)
          end
          if patterns = arguments["include"]?
            return "'include' is only valid with 'directory'" unless directory
            array = patterns.as_a?
            return "'include' must be an array of relative glob patterns" unless array && array.all? { |include_pattern| include_pattern.as_s?.try { |glob| !glob.starts_with?('/') && !glob.split('/').includes?("..") } }
          end

          nil
        end

        private def directory_search_files(directory : String, patterns : Array(String)?) : Array(String)
          root = File.realpath(directory)
          raise ArgumentError.new("Invalid search directory") unless File.directory?(root)
          paths = Index::FileDiscovery.paths(root).select do |path|
            real = File.realpath(path)
            next unless real.starts_with?(root + "/")
            relative = Path.new(path).relative_to(root).to_s
            (patterns.nil? || patterns.empty? || patterns.any? { |pattern| File.match?(pattern, relative) }) && !relative.starts_with?("../")
          end
          paths.uniq!
          paths.sort!
          raise ArgumentError.new("Directory search exceeds #{MAX_SEARCH_FILES} files") if paths.size > MAX_SEARCH_FILES
          total_size = paths.sum { |path| File.info(path).size }
          raise ArgumentError.new("Directory search exceeds #{MAX_SEARCH_BYTES} bytes") if total_size > MAX_SEARCH_BYTES
          paths
        end

        private def validate_search_files(file_contents : Hash(String, String), warnings : Array(String), input_name : String) : Types::SearchErrorResponse?
          return nil unless file_contents.empty?
          Types::SearchErrorResponse.new("No readable files in `#{input_name}`.", warnings)
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
        # Supports: ollama, openai, openrouter, deepseek (with CHIASMUS_EMBED_URL).
        # Ollama defaults to nomic-embed-text, others to text-embedding-3-small.
        private def resolve_embedding_model(resolution : EmbeddingResolution)
          case resolution.provider
          when "ollama"
            self.class.ollama_embedding_model(resolution.base_url, resolution.model_name)
          when "deepseek"
            api_key = resolution.api_key || return nil
            client = Crig::Providers::OpenAI::Client.new(api_key, resolution.base_url || "https://api.deepseek.com/v1")
            client.embedding_model(resolution.model_name)
          when "openrouter"
            api_key = resolution.api_key || return nil
            client = if base_url = resolution.base_url
                       Crig::Providers::OpenRouter::Client.new(api_key, base_url)
                     else
                       Crig::Providers::OpenRouter::Client.new(api_key)
                     end
            client.embedding_model(resolution.model_name)
          when "openai"
            api_key = resolution.api_key || return nil
            client = if base_url = resolution.base_url
                       Crig::Providers::OpenAI::Client.new(api_key, base_url)
                     else
                       Crig::Providers::OpenAI::Client.new(api_key)
                     end
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
              # DeepSeek exposes no /embeddings endpoint, so the key alone cannot
              # back chiasmus_search (upstream warns and returns null for the same
              # reason). Only honour it when CHIASMUS_EMBED_URL points at an
              # OpenAI-compatible embeddings endpoint such as a gateway or Ollama.
              if api_key = ENV["DEEPSEEK_API_KEY"]?
                if base_url
                  return EmbeddingResolution.new(
                    provider: "deepseek",
                    model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
                    api_key: api_key,
                    base_url: base_url,
                  )
                end
              end
            when "openai"
              if api_key = ENV["OPENAI_API_KEY"]?
                return EmbeddingResolution.new(
                  provider: "openai",
                  model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
                  api_key: api_key,
                  base_url: base_url,
                )
              end
            when "openrouter"
              if api_key = ENV["OPENROUTER_API_KEY"]?
                return EmbeddingResolution.new(
                  provider: "openrouter",
                  model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
                  api_key: api_key,
                  base_url: base_url,
                )
              end
            end

            return nil
          end

          # Local-first: a reachable Ollama embedding model is free, private, and
          # keeps source code off the network. It wins over ambient API keys
          # unless the user names a provider explicitly.
          if ollama_embedding_available?(base_url, ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT)
            return EmbeddingResolution.new(
              provider: "ollama",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || Crig::Providers::Ollama::NOMIC_EMBED_TEXT,
              base_url: base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL,
            )
          end

          if api_key = ENV["OPENAI_API_KEY"]?
            return EmbeddingResolution.new(
              provider: "openai",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
              api_key: api_key,
              base_url: base_url,
            )
          end

          if api_key = ENV["OPENROUTER_API_KEY"]?
            return EmbeddingResolution.new(
              provider: "openrouter",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
              api_key: api_key,
              base_url: base_url,
            )
          end

          # DEEPSEEK_API_KEY is deliberately not auto-selected: DeepSeek has no
          # embeddings API, so auto-selecting it produced a confusing 404.
          # CHIASMUS_EMBED_URL still routes the key at an OpenAI-compatible
          # endpoint when one is configured.
          if (api_key = ENV["DEEPSEEK_API_KEY"]?) && base_url
            return EmbeddingResolution.new(
              provider: "deepseek",
              model_name: ENV["CHIASMUS_EMBED_MODEL"]? || "text-embedding-3-small",
              api_key: api_key,
              base_url: base_url,
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

        # Whether chiasmus_search can actually run. Delegates to the resolver so
        # the gate can never drift from the provider chain it is gating, then
        # upgrades the implicit-Ollama default to a live check: a configured
        # local endpoint is only usable if the embedding model is pulled.
        def self.embedding_configured?(config : Utils::Config::ChiasmusConfig) : Bool
          # An unsupported provider value can only ever fail; keep the tool hidden.
          return false if explicit_embedding_configuration_error

          resolution = resolve_embedding_resolution(config) || return false

          explicit = explicitly_configured_provider?(config)
          return true if explicit

          case resolution.provider
          when "ollama"
            ollama_embedding_available?(resolution.base_url, resolution.model_name)
          else
            true
          end
        end

        # True when the user named a provider or shipped a key, as opposed to the
        # implicit local Ollama fallback, which has to be probe-verified.
        private def self.explicitly_configured_provider?(config : Utils::Config::ChiasmusConfig) : Bool
          return true if ENV["CHIASMUS_EMBED_PROVIDER"]?

          if local = config.local_embeddings
            return true if local.enabled? && local.model.try { |model| !model.blank? }
          end

          configured?(ENV["OPENAI_API_KEY"]?) ||
            configured?(ENV["OPENROUTER_API_KEY"]?) ||
            (configured?(ENV["DEEPSEEK_API_KEY"]?) && configured?(ENV["CHIASMUS_EMBED_URL"]?))
        end

        # Probe Ollama for the requested embedding model. Bounded so a hung or
        # remote endpoint cannot stall tool registration, and uncaught failures
        # degrade to "not available" rather than raising during handshake.
        def self.ollama_embedding_available?(base_url : String?, model : String) : Bool
          client : HTTP::Client? = nil
          begin
            uri = URI.parse(base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL)
            client = HTTP::Client.new(uri)
            client.connect_timeout = OLLAMA_PROBE_TIMEOUT
            client.read_timeout = OLLAMA_PROBE_TIMEOUT

            response = client.get("/api/tags", headers: HTTP::Headers{"Accept" => "application/json"})
            return false unless response.success?

            models = JSON.parse(response.body)["models"]?.try(&.as_a?) || return false
            models.any? do |entry|
              name = entry["name"]?.try(&.as_s?) || entry["model"]?.try(&.as_s?)
              next false unless name
              name == model || name == "#{model}:latest" || name.starts_with?("#{model}:")
            end
          rescue
            false
          ensure
            client.try(&.close) rescue nil
          end
        end

        # Actionable reason chiasmus_search cannot run, or nil when it can.
        def self.embedding_configuration_error(config : Utils::Config::ChiasmusConfig) : String?
          if error = explicit_embedding_configuration_error
            return error
          end

          resolution = resolve_embedding_resolution(config) || return no_provider_message

          if resolution.provider == "ollama" && !explicitly_configured_provider?(config)
            unless ollama_embedding_available?(resolution.base_url, resolution.model_name)
              return "No embedding provider configured. Ollama at #{resolution.base_url} does not serve " +
                "an embedding model named '#{resolution.model_name}'. Start Ollama and run " +
                "`ollama pull #{resolution.model_name}`, or #{no_provider_hint}."
            end
          end

          nil
        end

        # Env-only misconfiguration, deterministic and network-free so callers
        # can reject bad settings without depending on a live endpoint.
        def self.explicit_embedding_configuration_error : String?
          provider = ENV["CHIASMUS_EMBED_PROVIDER"]?
          return nil unless provider

          unless provider.in?(SUPPORTED_EMBED_PROVIDERS)
            return "Unsupported CHIASMUS_EMBED_PROVIDER=#{provider.inspect}. " +
              "Supported values: #{SUPPORTED_EMBED_PROVIDERS.join(", ")}."
          end

          if provider == "deepseek" && !configured?(ENV["CHIASMUS_EMBED_URL"]?)
            return "CHIASMUS_EMBED_PROVIDER=deepseek needs CHIASMUS_EMBED_URL: DeepSeek has no " +
              "embeddings API. Point it at an OpenAI-compatible embeddings endpoint " +
              "(for a local Ollama: CHIASMUS_EMBED_URL=#{Crig::Providers::Ollama::OLLAMA_API_BASE_URL})."
          end

          nil
        end

        private def self.no_provider_message : String
          "No embedding provider configured. #{no_provider_hint} " +
            "(see CHIASMUS_EMBED_* env vars for overrides)."
        end

        private def self.no_provider_hint : String
          "Run a local Ollama embedding model (CHIASMUS_EMBED_PROVIDER=ollama, " +
            "e.g. #{Crig::Providers::Ollama::NOMIC_EMBED_TEXT}), or set " +
            "OPENAI_API_KEY / OPENROUTER_API_KEY"
        end

        # Content hashes alone are insufficient because vectors from different
        # embedding models can share a dimension while inhabiting different
        # semantic spaces.
        def self.embedding_cache_path(home : String, resolution : EmbeddingResolution, dimension : Int32) : String
          namespace = OpenSSL::Digest.new("SHA256")
            .update(resolution.provider)
            .update("\u0000")
            .update(resolution.model_name)
            .final.hexstring[0, 16]
          File.join(home, "embeddings", "d#{dimension}-#{namespace}.json")
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

          Code is embedded with a configured provider, defaulting to a local
          Ollama embedding model when one is reachable.

          Provider selection (first match wins):
            CHIASMUS_EMBED_PROVIDER=ollama      → local Ollama (default nomic-embed-text)
            OPENAI_API_KEY                      → OpenAI text-embedding-3-small
            OPENROUTER_API_KEY                  → OpenRouter
            DEEPSEEK_API_KEY + CHIASMUS_EMBED_URL → OpenAI-compatible endpoint
            (no keys, no provider)              → local Ollama if reachable
          CHIASMUS_EMBED_MODEL → override default model
          CHIASMUS_EMBED_URL   → override base URL (e.g. a remote Ollama)

          Caches embeddings by content SHA-256 — unchanged code is not re-embedded.
          Directory searches accept an absolute directory and optional relative include globs.
          Discovery is limited to 500 source files and 25 MiB total; larger corpora return an error.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "query"     => ToolSchemas::SchemaProperty.new("string", "Natural language query for semantic search"),
              "files"     => ToolSchemas::Common.files_property,
              "directory" => ToolSchemas::SchemaProperty.new("string", "Absolute project directory to search"),
              "include"   => ToolSchemas::ArraySchemaProperty.new("Relative glob patterns to include within directory"),
              "top_k"     => ToolSchemas::SchemaProperty.new("number", "Number of results (1–100, default 10)"),
              "languages" => ToolSchemas::ArraySchemaProperty.new("Filter by language(s) — e.g. [\"go\", \"rust\"]. Uses Discovery pipeline with broader language support when specified."),
              "kinds"     => ToolSchemas::ArraySchemaProperty.new("Filter by symbol kind(s) — e.g. [\"class\", \"interface\"]. Requires languages param."),
            },
            required: ["query"]
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
