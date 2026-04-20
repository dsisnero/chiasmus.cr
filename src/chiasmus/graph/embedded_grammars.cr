require "file_utils"
require "base64"

module Chiasmus
  module Graph
    # Module for embedding grammar libraries into the binary and extracting them at runtime
    module EmbeddedGrammars
      extend self

      # List of embedded grammar languages
      EMBEDDED_LANGUAGES = [
        "ruby",
        "python",
        "java",
        "go",
        "rust",
        "scala",
        "javascript",
        "typescript",
        "tsx",
        "crystal",
      ]

      # Extract all embedded grammars to cache directory
      def extract_all_to_cache(cache_dir : String) : Bool
        Dir.mkdir_p(cache_dir)

        EMBEDDED_LANGUAGES.each do |language|
          unless extract_to_cache(language, cache_dir)
            return false
          end
        end

        true
      end

      # Extract a specific grammar to cache directory
      def extract_to_cache(language : String, cache_dir : String) : Bool
        # Get the embedded grammar data
        grammar_data = get_embedded_grammar(language)
        return false unless grammar_data

        # Determine library name based on platform
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"

        # Create language directory in cache
        lang_cache_dir = File.join(cache_dir, language)
        Dir.mkdir_p(lang_cache_dir)

        # Write the library file
        lib_path = File.join(lang_cache_dir, lib_name)
        File.write(lib_path, grammar_data)

        # Set executable permissions
        File.chmod(lib_path, 0o755)

        true
      rescue ex
        false
      end

      # Check if a grammar is embedded
      def embedded?(language : String) : Bool
        EMBEDDED_LANGUAGES.includes?(language)
      end

      # Get embedded grammar data
      private def get_embedded_grammar(language : String) : Bytes?
        # Try to get embedded data first
        embedded_data = get_compile_time_embedded_grammar(language)
        return embedded_data if embedded_data

        # Fall back to vendor directory for development
        vendor_path = find_vendor_grammar(language)
        return nil unless vendor_path

        File.read(vendor_path).to_slice
      end

      # Get grammar data embedded at compile time
      private def get_compile_time_embedded_grammar(language : String) : Bytes?
        # For now, we'll use runtime loading from vendor directory
        # In a production build, we would embed the files at compile time
        # using a build script that generates Crystal code with embedded binaries
        nil
      end

      # Find grammar in vendor directory (fallback for development)
      private def find_vendor_grammar(language : String) : String?
        vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)

        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"

        # Check in language-specific directory
        paths = [
          File.join(vendor_dir, "tree-sitter-#{language}", lib_name),
          File.join(vendor_dir, "tree-sitter-#{language}", language, lib_name), # For TypeScript/TSX
          File.join(vendor_dir, language, lib_name),
        ]

        paths.find { |path| File.exists?(path) }
      end
    end
  end
end
