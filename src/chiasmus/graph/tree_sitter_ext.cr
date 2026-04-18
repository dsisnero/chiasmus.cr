require "tree_sitter"

module Chiasmus
  module Graph
    # Monkey-patch TreeSitter::Repository to support bundled grammars
    # and additional search paths
    module TreeSitterRepositoryExtension
      @@bundled_grammar_paths = {} of String => String
      @@additional_parser_dirs = [] of String

      # Register a bundled grammar at a specific path
      def self.register_bundled_grammar(language : String, grammar_path : String)
        @@bundled_grammar_paths[language] = grammar_path
      end

      # Add additional parser directories
      def self.add_parser_directory(path : String)
        @@additional_parser_dirs << path unless @@additional_parser_dirs.includes?(path)
      end

      # Extended language_paths that includes bundled grammars and additional dirs
      def self.extended_language_paths : Hash(String, String)
        paths = {} of String => String

        # First check bundled grammars
        @@bundled_grammar_paths.each do |language, grammar_path|
          # Check if the grammar exists at this path
          if Dir.exists?(grammar_path)
            paths[language] = grammar_path
          end
        end

        # Then check additional parser directories
        @@additional_parser_dirs.each do |dir|
          next unless Dir.exists?(dir)

          # Look for grammar.json files like the original Repository does
          Dir.glob(File.join(dir, "**", "src", "grammar.json")).each do |grammar_path|
            if grammar_path =~ %r{.*/tree\-sitter\-([\w\-_]+)/src/grammar.json\z}
              language = $1
              grammar_dir = File.dirname(File.dirname(grammar_path))
              paths[language] = grammar_dir unless paths.has_key?(language)
            end
          end
        end

        # Finally include the original repository paths
        TreeSitter::Repository.language_paths.each do |language, path|
          paths[language] = path.to_s unless paths.has_key?(language)
        end

        paths
      end

      # Try to load a language with extended search
      def self.load_language_ext(language : String) : TreeSitter::Language?
        paths = extended_language_paths

        if grammar_dir = paths[language]?
          # Convert to Path for the original load_language method
          _ = Path.new(grammar_dir)

          # We need to call the protected load_shared_object method
          # For now, we'll try to use the public API
          begin
            # Try the standard way first
            return TreeSitter::Repository.load_language?(language)
          rescue ex
            # If that fails, try loading directly from the path
            # This would require access to load_shared_object
            nil
          end
        end

        nil
      end

      # Get all available languages
      def self.available_languages : Array(String)
        extended_language_paths.keys.sort!
      end

      # Initialize with default paths
      def self.init_defaults
        # Add our vendored grammar directories
        vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
        if Dir.exists?(vendor_dir)
          add_parser_directory(vendor_dir)

          # Also add each grammar directory individually
          Dir.children(vendor_dir).each do |dir|
            full_path = File.join(vendor_dir, dir)
            if dir.starts_with?("tree-sitter-") && Dir.exists?(full_path)
              language = dir.sub("tree-sitter-", "")
              register_bundled_grammar(language, full_path)
            end
          end
        end

        # Add standard locations
        {% if flag?(:darwin) %}
          add_parser_directory("/usr/local/lib")
          add_parser_directory("#{ENV["HOME"]}/.local/lib")
        {% else %}
          add_parser_directory("/usr/lib")
          add_parser_directory("/usr/local/lib")
          add_parser_directory("#{ENV["HOME"]}/.local/lib")
        {% end %}
      end
    end

    # Now let's create a parser that uses our extended repository
    class UniversalParser
      def self.parse_source(content : String, file_path : String) : TreeSitter::Tree?
        language = Parser.get_language_for_file(file_path)
        return nil unless language

        # Try to load the language using our extended repository
        lang = TreeSitterRepositoryExtension.load_language_ext(language)
        return nil unless lang

        # Create parser and parse
        parser = TreeSitter::Parser.new(language: lang)
        io = IO::Memory.new(content)
        parser.parse(nil, io)
      end

      # Build a grammar from source if not available
      def self.build_grammar_if_needed(language : String) : Bool
        # Check if already available
        return true if TreeSitterRepositoryExtension.available_languages.includes?(language)

        # Check if we have source code for this grammar
        grammar_source_dir = find_grammar_source(language)
        return false unless grammar_source_dir && Dir.exists?(grammar_source_dir)

        # Try to build the grammar
        build_grammar(grammar_source_dir, language)
      end

      private def self.find_grammar_source(language : String) : String?
        # Look in our vendored grammars
        vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
        grammar_dir = File.join(vendor_dir, "tree-sitter-#{language}")

        if Dir.exists?(grammar_dir)
          return grammar_dir
        end

        nil
      end

      private def self.build_grammar(source_dir : String, language : String) : Bool
        # This would require tree-sitter CLI to be installed
        # For now, just return false
        false
      end
    end
  end
end
