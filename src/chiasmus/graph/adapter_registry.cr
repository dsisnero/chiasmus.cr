require "json"
require "mutex"
require "./types"

module Chiasmus
  module Graph
    module AdapterRegistry
      extend self

      @@mutex = Mutex.new
      @@adapters = {} of String => LanguageAdapter
      @@adapter_factories = {} of String => AdapterFactory
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

      def register_adapter_factory(entrypoint : String, factory : AdapterFactory) : Nil
        @@mutex.synchronize do
          @@adapter_factories[entrypoint] = factory
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

      def clear_adapter_factories : Nil
        @@mutex.synchronize do
          @@adapter_factories.clear
        end
      end

      # Crystal-native discovery uses manifest descriptors plus registered factories
      # instead of arbitrary runtime module loading.
      def discover_adapters(manifest_paths : Array(String) = default_manifest_paths, diagnostics : Array(String)? = nil) : Nil
        should_run = @@mutex.synchronize do
          next false if @@discovered
          @@discovered = true
          true
        end
        return unless should_run

        discover_manifest_paths(manifest_paths, diagnostics)
      rescue ex
        diagnostics.try(&.<<("adapter discovery failed: #{ex.message}"))
      end

      private def discover_manifest_paths(manifest_paths : Array(String), diagnostics : Array(String)?) : Nil
        queue = manifest_paths.dup
        seen = Set(String).new

        until queue.empty?
          manifest_path = File.expand_path(queue.shift)
          next unless seen.add?(manifest_path)

          descriptors = parse_manifest(manifest_path, diagnostics)
          descriptors.each do |descriptor|
            adapter = build_adapter(descriptor, diagnostics)
            next unless adapter

            register_adapter(adapter)
            adapter.search_paths.try do |paths|
              queue.concat(paths.flat_map { |path| manifest_paths_for_search_path(path) })
            end
          end
        end
      end

      private def parse_manifest(path : String, diagnostics : Array(String)?) : Array(AdapterDescriptor)
        return [] of AdapterDescriptor unless File.exists?(path)

        raw = JSON.parse(File.read(path))
        adapter_values = raw["adapters"]?.try(&.as_a?)
        return [] of AdapterDescriptor unless adapter_values

        adapter_values.compact_map do |value|
          descriptor_from_json(value, path, diagnostics)
        end
      rescue ex
        diagnostics.try(&.<<("skipped adapter manifest #{path}: #{ex.message}"))
        [] of AdapterDescriptor
      end

      private def descriptor_from_json(value : JSON::Any, path : String, diagnostics : Array(String)?) : AdapterDescriptor?
        object = value.as_h?
        unless object
          diagnostics.try(&.<<("skipped adapter descriptor in #{path}: descriptor must be an object"))
          return nil
        end

        language = object["language"]?.try(&.as_s?)
        extensions = string_array(object["extensions"]?)
        entrypoint = object["entrypoint"]?.try(&.as_s?)
        grammar_language = object["grammar_language"]?.try(&.as_s?) || object["grammarLanguage"]?.try(&.as_s?) || language
        search_paths = string_array(object["search_paths"]?) || string_array(object["searchPaths"]?)

        if language.nil? || extensions.nil? || extensions.empty? || entrypoint.nil? || grammar_language.nil?
          diagnostics.try(&.<<("skipped adapter descriptor in #{path}: language, extensions, and entrypoint are required"))
          return nil
        end

        AdapterDescriptor.new(
          language: language,
          extensions: extensions,
          grammar_language: grammar_language,
          entrypoint: entrypoint,
          search_paths: search_paths
        )
      end

      private def build_adapter(descriptor : AdapterDescriptor, diagnostics : Array(String)?) : LanguageAdapter?
        factory = @@mutex.synchronize { @@adapter_factories[descriptor.entrypoint]? }
        unless factory
          diagnostics.try(&.<<("skipped adapter #{descriptor.language}: no factory registered for #{descriptor.entrypoint}"))
          return nil
        end

        factory.build(descriptor)
      rescue ex
        diagnostics.try(&.<<("skipped adapter #{descriptor.language}: #{ex.message}"))
        nil
      end

      private def string_array(value : JSON::Any?) : Array(String)?
        values = value.try(&.as_a?)
        return nil unless values

        values.compact_map(&.as_s?)
      end

      private def default_manifest_paths : Array(String)
        [File.join(Dir.current, "chiasmus.adapters.json")]
      end

      private def manifest_paths_for_search_path(path : String) : Array(String)
        return [] of String unless Dir.exists?(path)

        Dir.children(path).compact_map do |entry|
          next unless entry == "chiasmus.adapters.json" || entry.ends_with?(".adapters.json")

          File.join(path, entry)
        end
      rescue
        [] of String
      end

      private def normalize_extension(ext : String) : String
        normalized = ext.downcase
        normalized.starts_with?('.') ? normalized : ".#{normalized}"
      end
    end
  end
end
