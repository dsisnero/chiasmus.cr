require "tree_sitter"
require "./parser"
require "./async_grammar_manager_v2"
require "./language_loader"
require "../utils/timeout"
require "../utils/result"

module Chiasmus
  module Graph
    # Production-ready async universal parser
    class AsyncUniversalParserV2
      @@initialized = false
      @@grammar_cache = {} of String => TreeSitter::Language?
      @@pending_requests = {} of String => Array(Channel(Utils::Result(TreeSitter::Language?)))
      @@supported_languages_cache : Array(String)? = nil

      # Initialize the async parser
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        # Initialize async grammar manager
        AsyncGrammarManagerV2.init(cache_dir)

        @@initialized = true
      end

      # Parse source code asynchronously
      # Returns a Channel that will receive a Result(TreeSitter::Tree?)
      def self.parse_async(content : String, file_path : String, timeout_ms : Int32 = 30_000) : Channel(Utils::Result(TreeSitter::Tree?))
        init unless @@initialized

        result_channel = Channel(Utils::Result(TreeSitter::Tree?)).new

        spawn do
          begin
            language = Parser.get_language_for_file(file_path)
            unless language
              result_channel.send(Utils::Result(TreeSitter::Tree?).failure(
                "Unsupported file extension",
                {"file_path" => file_path}
              ))
              next
            end

            # Get language asynchronously with timeout
            lang_channel = get_language_async(language)
            lang_result = Utils::Timeout.with_timeout_async(timeout_ms, lang_channel)

            unless lang_result
              result_channel.send(Utils::Result(TreeSitter::Tree?).failure(
                "Timeout getting language",
                {"language" => language, "file_path" => file_path, "timeout_ms" => timeout_ms.to_s}
              ))
              next
            end

            if lang_result.failure?
              result_channel.send(Utils::Result(TreeSitter::Tree?).failure(
                "Failed to get language: #{lang_result.error}",
                lang_result.details.merge({"language" => language, "file_path" => file_path})
              ))
              next
            end

            lang = lang_result.unwrap

            # Parse with the obtained language
            parser = TreeSitter::Parser.new(language: lang)
            io = IO::Memory.new(content)
            tree = parser.parse(nil, io)

            result_channel.send(Utils::Result(TreeSitter::Tree?).success(tree))
          rescue ex
            result_channel.send(Utils::Result(TreeSitter::Tree?).failure(
              "Unexpected error parsing file: #{ex.message}",
              {"file_path" => file_path, "exception" => ex.class.to_s}
            ))
          end
        end

        result_channel
      end

      # Get a language asynchronously, with intelligent caching
      def self.get_language_async(language : String, timeout_ms : Int32 = 60_000) : Channel(Utils::Result(TreeSitter::Language?))
        # Check cache first (fast path)
        if lang = @@grammar_cache[language]?
          channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
          channel.send(Utils::Result(TreeSitter::Language?).success(lang))
          return channel
        end

        # Check if there's already a pending request for this language
        if waiters = @@pending_requests[language]?
          channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
          waiters << channel
          return channel
        end

        # Create new request
        result_channel = Channel(Utils::Result(TreeSitter::Language?)).new(1)
        @@pending_requests[language] = [result_channel]

        spawn do
          begin
            # Try to load from system first (fast check)
            lang = try_load_language(language)
            if lang
              @@grammar_cache[language] = lang
              notify_waiters(language, Utils::Result(TreeSitter::Language?).success(lang))
              next
            end

            # Language not available, try to ensure it with timeout
            ensure_channel = AsyncGrammarManagerV2.ensure_grammar_async(language)
            ensure_result = Utils::Timeout.with_timeout_async(timeout_ms, ensure_channel)

            unless ensure_result
              notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
                "Timeout ensuring grammar",
                {"language" => language, "timeout_ms" => timeout_ms.to_s}
              ))
              next
            end

            if ensure_result.failure?
              notify_waiters(language, Utils::Result(TreeSitter::Language?).failure(
                "Failed to ensure grammar: #{ensure_result.error}",
                ensure_result.details.merge({"language" => language})
              ))
              next
            end

            # Try to load again
            lang = try_load_language(language)
            if lang
              @@grammar_cache[language] = lang
              notify_waiters(language, Utils::Result(TreeSitter::Language?).success(lang))
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
            @@pending_requests.delete(language)
          end
        end

        result_channel
      end

      # Check if a language is supported asynchronously (with optimization)
      def self.supports_language_async?(language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          # Check if it's in our language mapping
          unless Parser::EXT_MAP.values.includes?(language)
            channel.send(false)
            next
          end

          # Fast path: check cache
          if @@grammar_cache[language]?
            channel.send(true)
            next
          end

          # Check if available
          available_channel = AsyncGrammarManagerV2.grammar_available_async(language)
          available = available_channel.receive

          channel.send(available)
        end

        channel
      end

      # Get all supported languages asynchronously (optimized)
      def self.supported_languages_async : Channel(Array(String))
        channel = Channel(Array(String)).new

        spawn do
          # Return cached result if available
          if cached = @@supported_languages_cache
            channel.send(cached)
            next
          end

          # Get unique languages from EXT_MAP
          all_languages = Parser::EXT_MAP.values.uniq!
          supported = [] of String

          # Check system grammars first (fast)
          system_grammars = TreeSitter::Repository.language_names
          fast_supported = all_languages.select { |lang| system_grammars.includes?(lang) }
          supported.concat(fast_supported)

          # Remaining languages to check
          remaining = all_languages - fast_supported

          if !remaining.empty?
            # Check remaining languages concurrently but with limit
            # to avoid overwhelming the system
            batch_size = 5
            remaining.each_slice(batch_size) do |batch|
              batch_channels = batch.map do |language|
                supports_channel = supports_language_async?(language)
                {language, supports_channel}
              end

              batch_channels.each do |language, supports_channel|
                if supports_channel.receive
                  supported << language
                end
              end
            end
          end

          # Cache the result
          @@supported_languages_cache = supported
          channel.send(supported)
        end

        channel
      end

      # Clear cache (useful for testing or when grammars are added/removed)
      def self.clear_cache
        @@grammar_cache.clear
        @@pending_requests.clear
        @@supported_languages_cache = nil
      end

      # Shutdown (cleanup resources if needed)
      def self.shutdown
        clear_cache
        @@initialized = false
      end

      # Helper method to try loading a language
      private def self.try_load_language(language : String) : TreeSitter::Language?
        # Try to get path
        path_channel = AsyncGrammarManagerV2.get_grammar_path_async(language)
        if path_result = Utils::Timeout.with_timeout_async(5_000, path_channel)
          if path_result.success? && (path = path_result.value)
            return LanguageLoader.load_language_from_grammar_path(language, path)
          end
        end

        nil
      rescue
        nil
      end

      private def self.notify_waiters(language : String, result : Utils::Result(TreeSitter::Language?))
        return unless waiters = @@pending_requests[language]?
        waiters.each do |waiter|
          waiter.send(result)
        end
      end
    end
  end
end
