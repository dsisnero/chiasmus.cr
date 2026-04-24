require "tree_sitter"
require "./grammar_manager"
require "./language_loader"
require "./parser_language_resolver"
require "./parser_environment"
require "../utils/result"
require "../utils/timeout"

module Chiasmus
  module Graph
    module Parser
      class GrammarGateway
        def init(cache_dir : String? = nil) : Nil
          GrammarManager.init(cache_dir)
        end

        def ensure_grammar_async(language : String, timeout_ms : Int32 = 120_000) : Channel(Utils::BoolResult)
          GrammarManager.instance.ensure_grammar_async(language, timeout_ms)
        end

        def grammar_available_async(language : String) : Channel(Utils::BoolResult)
          GrammarManager.instance.grammar_available_async(language)
        end

        def get_grammar_path_async(language : String) : Channel(Utils::StringResult)
          GrammarManager.instance.get_grammar_path_async(language)
        end

        def ensure_grammar(language : String, timeout_ms : Int32 = 120_000) : Bool
          GrammarManager.ensure_grammar(language, timeout_ms)
        end

        def get_grammar_path(language : String) : String?
          GrammarManager.get_grammar_path(language)
        end
      end

      class LanguageGateway
        def repository_language_names : Array(String)
          TreeSitter::Repository.language_names
        end

        def load_language_from_grammar_path(language : String, grammar_path : String) : TreeSitter::Language?
          LanguageLoader.load_language_from_grammar_path(language, grammar_path)
        end
      end

      class TreeBuilder
        def build(lang : TreeSitter::Language, content : String) : TreeSitter::Tree?
          parser = TreeSitter::Parser.new(language: lang)
          io = IO::Memory.new(content)
          parser.parse(nil, io)
        end
      end

      class ParseRunner
        def initialize(
          @resolver : LanguageResolver,
          @grammar_gateway : GrammarGateway,
          @language_gateway : LanguageGateway,
          @tree_builder : TreeBuilder,
          @grammar_cache : Hash(String, TreeSitter::Language?),
        )
        end

        def run(content : String, file_path : String, timeout_ms : Int32) : ParseOutcome
          logical_language = @resolver.language_for_file(file_path)
          return unsupported_file_result(file_path) unless logical_language

          grammar_language = @resolver.grammar_language_for_file(file_path)
          return unsupported_file_result(file_path) unless grammar_language

          lang = resolve_language(grammar_language, timeout_ms)
          return missing_language_result(logical_language, grammar_language, file_path, timeout_ms) unless lang

          ParseOutcome.new(tree: @tree_builder.build(lang, content))
        rescue ex
          unexpected_parse_error(file_path, ex)
        end

        private def resolve_language(language : String, timeout_ms : Int32) : TreeSitter::Language?
          cached = @grammar_cache[language]?
          return cached if cached

          lang = try_load_language(language)
          if lang
            @grammar_cache[language] = lang
            return lang
          end

          return nil unless @grammar_gateway.ensure_grammar(language, timeout_ms)

          lang = try_load_language(language)
          @grammar_cache[language] = lang if lang
          lang
        end

        private def try_load_language(language : String) : TreeSitter::Language?
          if path = @grammar_gateway.get_grammar_path(language)
            return @language_gateway.load_language_from_grammar_path(language, path)
          end

          nil
        rescue
          nil
        end

        private def unsupported_file_result(file_path : String) : ParseOutcome
          ParseOutcome.new(error: "Unsupported file extension", details: {"file_path" => file_path})
        end

        private def missing_language_result(
          logical_language : String,
          grammar_language : String,
          file_path : String,
          timeout_ms : Int32,
        ) : ParseOutcome
          ParseOutcome.new(
            error: "Failed to get language",
            details: {
              "language"         => grammar_language,
              "logical_language" => logical_language,
              "file_path"        => file_path,
              "timeout_ms"       => timeout_ms.to_s,
            }
          )
        end

        private def unexpected_parse_error(file_path : String, ex : Exception) : ParseOutcome
          ParseOutcome.new(
            error: "Unexpected error parsing file: #{ex.message}",
            details: {"file_path" => file_path, "exception" => ex.class.to_s}
          )
        end
      end

      class Service
        getter grammar_cache, pending_requests
        getter supported_languages_cache

        def initialize(
          @resolver = LanguageResolver.new,
          @environment = Environment.new,
          @grammar_gateway = GrammarGateway.new,
          @language_gateway = LanguageGateway.new,
          @tree_builder = TreeBuilder.new,
        )
          @initialized = false
          @grammar_cache = {} of String => TreeSitter::Language?
          @pending_requests = {} of String => Array(Channel(Utils::Result(TreeSitter::Language?)))
          @supported_languages_cache = nil.as(Array(String)?)
        end

        def init(cache_dir : String? = nil) : Nil
          return if @initialized

          @environment.ensure_tree_sitter_config
          @grammar_gateway.init(cache_dir)
          @initialized = true
        end

        def get_language_for_file(file_path : String) : String?
          @resolver.language_for_file(file_path)
        end

        def grammar_language_for_file(file_path : String) : String?
          @resolver.grammar_language_for_file(file_path)
        end

        def supported_extensions : Array(String)
          @resolver.supported_extensions
        end

        def parse_async(content : String, file_path : String, timeout_ms : Int32 = 30_000) : Channel(Utils::Result(ParseArtifact))
          init unless @initialized

          result_channel = Channel(Utils::Result(ParseArtifact)).new

          spawn do
            result_channel.send(to_parse_result(parse_runner.run(content, file_path, timeout_ms)))
          end

          result_channel
        end

        def parse(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
          parse_runner.run(content, file_path, timeout_ms).tree
        end

        def get_language_async(language : String, timeout_ms : Int32 = 60_000) : Channel(Utils::Result(TreeSitter::Language?))
          init unless @initialized

          if cached = @grammar_cache[language]?
            return resolved_language_channel(cached)
          end

          if waiters = @pending_requests[language]?
            channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
            waiters << channel
            return channel
          end

          result_channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
          @pending_requests[language] = [result_channel]

          spawn do
            resolve_language(language, timeout_ms)
          end

          result_channel
        end

        def get_language(language : String, timeout_ms : Int32 = 60_000) : TreeSitter::Language?
          result = Utils::Timeout.with_timeout_async(timeout_ms, get_language_async(language, timeout_ms))
          return nil unless result && result.success?

          result.value
        end

        def supports_language_async?(language : String) : Channel(Bool)
          channel = Channel(Bool).new

          spawn do
            channel.send(compute_support(language))
          end

          channel
        end

        def supports_language?(language : String) : Bool
          Utils::Timeout.with_timeout_async(60_000, supports_language_async?(language)) || false
        end

        def supported_languages_async : Channel(Array(String))
          channel = Channel(Array(String)).new

          spawn do
            channel.send(compute_supported_languages)
          end

          channel
        end

        def supported_languages : Array(String)
          Utils::Timeout.with_timeout_async(60_000, supported_languages_async) || [] of String
        end

        def clear_cache : Nil
          @grammar_cache.clear
          @pending_requests.clear
          @supported_languages_cache = nil
        end

        def shutdown : Nil
          clear_cache
          @initialized = false
        end

        def reset_for_test : Nil
          shutdown
        end

        def seed_cache_for_test(language : String, lang : TreeSitter::Language) : Nil
          @grammar_cache[language] = lang
        end

        def seed_waiters_for_test(language : String, count : Int32) : Array(Channel(Utils::Result(TreeSitter::Language?)))
          waiters = Array(Channel(Utils::Result(TreeSitter::Language?))).new(count) do
            Channel(Utils::Result(TreeSitter::Language?)).new(1)
          end
          @pending_requests[language] = waiters
          waiters
        end

        def notify_for_test(language : String, result : Utils::Result(TreeSitter::Language?)) : Nil
          notify_waiters(language, result)
        end

        private def to_parse_result(outcome : ParseOutcome) : Utils::Result(ParseArtifact)
          if outcome.success?
            Utils::Result(ParseArtifact).success(ParseArtifact.new(outcome.tree))
          else
            Utils::Result(ParseArtifact).failure(outcome.error || "Unknown parse error", outcome.details)
          end
        end

        private def resolve_language(language : String, timeout_ms : Int32) : Nil
          lang = try_load_language(language)
          if lang
            @grammar_cache[language] = lang
            notify_waiters(language, Utils::Result(TreeSitter::Language?).success(lang))
            return
          end

          ensure_channel = @grammar_gateway.ensure_grammar_async(language, timeout_ms)
          ensure_result = Utils::Timeout.with_timeout_async(timeout_ms, ensure_channel)

          unless ensure_result
            notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
              "Timeout ensuring grammar",
              {"language" => language, "timeout_ms" => timeout_ms.to_s}
            ))
            return
          end

          if ensure_result.failure?
            notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
              "Failed to ensure grammar: #{ensure_result.error}",
              ensure_result.details.merge({"language" => language})
            ))
            return
          end

          final_lang = try_load_language(language)
          if final_lang
            @grammar_cache[language] = final_lang
            notify_waiters(language, Utils::Result(TreeSitter::Language?).success(final_lang))
          else
            notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
              "Grammar ensured but failed to load",
              {"language" => language}
            ))
          end
        rescue ex
          notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
            "Unexpected error getting language: #{ex.message}",
            {"language" => language, "exception" => ex.class.to_s}
          ))
        ensure
          @pending_requests.delete(language)
        end

        private def compute_support(language : String) : Bool
          return false unless @resolver.known_language?(language)
          return true if @grammar_cache[language]?

          result = @grammar_gateway.grammar_available_async(language).receive
          result.success? && result.value == true
        end

        private def compute_supported_languages : Array(String)
          if cached = @supported_languages_cache
            return cached
          end

          all_languages = @resolver.supported_languages
          supported = [] of String

          system_grammars = @language_gateway.repository_language_names
          fast_supported = all_languages.select { |lang| system_grammars.includes?(lang) }
          supported.concat(fast_supported)

          remaining = all_languages - fast_supported
          remaining.each_slice(5) do |batch|
            batch_channels = batch.map { |language| {language, supports_language_async?(language)} }
            batch_channels.each do |language, supports_channel|
              supported << language if supports_channel.receive
            end
          end

          @supported_languages_cache = supported
          supported
        end

        private def resolved_language_channel(lang : TreeSitter::Language?) : Channel(Utils::Result(TreeSitter::Language?))
          channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
          channel.send(Utils::Result(TreeSitter::Language?).success(lang))
          channel
        end

        private def parse_runner : ParseRunner
          ParseRunner.new(
            @resolver,
            @grammar_gateway,
            @language_gateway,
            @tree_builder,
            @grammar_cache
          )
        end

        private def try_load_language(language : String) : TreeSitter::Language?
          path_channel = @grammar_gateway.get_grammar_path_async(language)
          if path_result = Utils::Timeout.with_timeout_async(5_000, path_channel)
            if path_result.success? && (path = path_result.value)
              return @language_gateway.load_language_from_grammar_path(language, path)
            end
          end

          nil
        rescue
          nil
        end

        private def notify_waiters(language : String, result : Utils::Result(TreeSitter::Language?)) : Nil
          return unless waiters = @pending_requests[language]?
          waiters.each(&.send(result))
        end
      end
    end
  end
end
