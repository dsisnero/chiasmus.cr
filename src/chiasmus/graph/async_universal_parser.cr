require "tree_sitter"
require "./parser"
require "./async_grammar_manager"
require "./language_loader"

module Chiasmus
  module Graph
    # Async universal parser that never blocks
    class AsyncUniversalParser
      @@initialized = false
      @@grammar_cache = {} of String => TreeSitter::Language?
      @@pending_requests = {} of String => Array(Channel(TreeSitter::Language?))

      # Initialize the async parser
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        # Start the async grammar manager worker
        AsyncGrammarManager.start_worker(cache_dir)

        @@initialized = true
      end

      # Parse source code asynchronously
      # Returns a Channel that will receive the Tree or nil
      def self.parse_async(content : String, file_path : String) : Channel(TreeSitter::Tree?)
        init unless @@initialized

        result_channel = Channel(TreeSitter::Tree?).new

        spawn do
          language = Parser.get_language_for_file(file_path)
          unless language
            result_channel.send(nil)
            next
          end

          # Get language asynchronously
          lang_channel = get_language_async(language)
          lang = lang_channel.receive

          unless lang
            result_channel.send(nil)
            next
          end

          # Parse with the obtained language
          parser = TreeSitter::Parser.new(language: lang)
          io = IO::Memory.new(content)
          tree = parser.parse(nil, io)

          result_channel.send(tree)
        end

        result_channel
      end

      # Get a language asynchronously, with caching
      def self.get_language_async(language : String) : Channel(TreeSitter::Language?)
        # Check cache first
        if lang = @@grammar_cache[language]?
          channel = Channel(TreeSitter::Language?).new(1)
          channel.send(lang)
          return channel
        end

        # Check if there's already a pending request for this language
        if waiters = @@pending_requests[language]?
          channel = Channel(TreeSitter::Language?).new(1)
          waiters << channel
          return channel
        end

        # Create new request
        result_channel = Channel(TreeSitter::Language?).new(1)
        @@pending_requests[language] = [result_channel]

        spawn do
          begin
            # Check if grammar is available
            available_channel = AsyncGrammarManager.grammar_available_async(language)
            available = available_channel.receive

            if available
              # Try to load from system
              lang = load_language_from_system(language)
              if lang
                @@grammar_cache[language] = lang
                notify_waiters(language, lang)
                next
              end
            end

            # Grammar not available, try to ensure it
            ensure_channel = AsyncGrammarManager.ensure_grammar_async(language)
            success = ensure_channel.receive

            if success
              # Try to load again
              lang = load_language_from_system(language)
              @@grammar_cache[language] = lang if lang
              notify_waiters(language, lang)
            else
              notify_waiters(language, nil)
            end
          rescue ex
            notify_waiters(language, nil)
          ensure
            @@pending_requests.delete(language)
          end
        end

        result_channel
      end

      # Check if a language is supported asynchronously
      def self.supports_language_async?(language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          # Check if it's in our language mapping
          unless Parser::EXT_MAP.values.includes?(language)
            channel.send(false)
            next
          end

          # Check if available or can be built
          lang_channel = get_language_async(language)
          lang = lang_channel.receive
          channel.send(lang != nil)
        end

        channel
      end

      # Get all supported languages asynchronously
      def self.supported_languages_async : Channel(Array(String))
        channel = Channel(Array(String)).new

        spawn do
          # Get unique languages from EXT_MAP
          languages = Parser::EXT_MAP.values.uniq!
          supported = [] of String

          # Check each language concurrently
          channels = languages.map do |language|
            supports_channel = supports_language_async?(language)
            {language, supports_channel}
          end

          channels.each do |language, supports_channel|
            if supports_channel.receive
              supported << language
            end
          end

          channel.send(supported)
        end

        channel
      end

      # Shutdown async components
      def self.shutdown
        AsyncGrammarManager.shutdown
        @@initialized = false
        @@grammar_cache.clear
        @@pending_requests.clear
      end

      # Helper method to load language from system
      private def self.load_language_from_system(language : String) : TreeSitter::Language?
        # Try to get path from async manager
        path_channel = AsyncGrammarManager.get_grammar_path_async(language)
        if path = path_channel.receive
          return LanguageLoader.load_language_from_grammar_path(language, path)
        end

        nil
      rescue
        nil
      end

      private def self.notify_waiters(language : String, result : TreeSitter::Language?)
        return unless waiters = @@pending_requests[language]?
        waiters.each do |waiter|
          waiter.send(result)
        end
      end
    end
  end
end
