require "mutex"
require "./types"

module Chiasmus
  module Graph
    module AdapterRegistry
      extend self

      @@mutex = Mutex.new
      @@adapters = {} of String => LanguageAdapter
      @@extension_map = {} of String => String
      @@grammar_extension_map = {} of String => String
      @@discovered = false

      def register_adapter(adapter : LanguageAdapter) : Nil
        @@mutex.synchronize do
          @@adapters[adapter.language] = adapter
          adapter.extensions.each do |ext|
            normalized = normalize_extension(ext)
            @@extension_map[normalized] = adapter.language
            @@grammar_extension_map[normalized] = adapter.grammar_language
          end
        end
      end

      def get_adapter(language : String) : LanguageAdapter?
        @@mutex.synchronize { @@adapters[language]? }
      end

      def get_adapter_for_ext(ext : String) : LanguageAdapter?
        language = @@mutex.synchronize { @@extension_map[normalize_extension(ext)]? }
        return nil unless language

        get_adapter(language)
      end

      def language_for_ext(ext : String) : String?
        @@mutex.synchronize { @@extension_map[normalize_extension(ext)]? }
      end

      def grammar_language_for_ext(ext : String) : String?
        @@mutex.synchronize { @@grammar_extension_map[normalize_extension(ext)]? }
      end

      def adapter_extensions : Array(String)
        @@mutex.synchronize { @@extension_map.keys.sort! }
      end

      def clear_adapters : Nil
        @@mutex.synchronize do
          @@adapters.clear
          @@extension_map.clear
          @@grammar_extension_map.clear
          @@discovered = false
        end
      end

      # Crystal port currently supports explicit registration only.
      # Keep discovery idempotent and non-throwing to preserve the public contract.
      def discover_adapters : Nil
        @@mutex.synchronize do
          return if @@discovered

          @@discovered = true
        end
      end

      private def normalize_extension(ext : String) : String
        normalized = ext.downcase
        normalized.starts_with?('.') ? normalized : ".#{normalized}"
      end
    end
  end
end
