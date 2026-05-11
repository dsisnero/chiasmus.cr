module Chiasmus
  module Discovery
    # Maps file extensions to language extractors.
    # Thread-safe: only reads after construction.
    class ExtractorRegistry
      getter extractors : Hash(String, LanguageExtractor)
      getter extension_map : Hash(String, LanguageExtractor)

      def initialize(extractors : Array(LanguageExtractor))
        @extractors = {} of String => LanguageExtractor
        @extension_map = {} of String => LanguageExtractor

        extractors.each do |extractor|
          key = extractor.language
          # First registration wins
          register(key, extractor) unless @extractors.has_key?(key)
        end
      end

      def register(language : String, extractor : LanguageExtractor) : Nil
        return if @extractors.has_key?(language)
        @extractors[language] = extractor
        extractor.extensions.each do |ext|
          @extension_map[ext] = extractor unless @extension_map.has_key?(ext)
        end
      end

      def for_file(file_path : String) : LanguageExtractor?
        @extension_map.each do |ext, extractor|
          return extractor if file_path.ends_with?(ext)
        end
        nil
      end

      def for_language(language : String) : LanguageExtractor?
        @extractors[language]?
      end

      def supported_extensions : Array(String)
        @extension_map.keys.sort!
      end

      def languages : Array(String)
        @extractors.keys.sort!
      end

      def size : Int32
        @extractors.size
      end
    end
  end
end
