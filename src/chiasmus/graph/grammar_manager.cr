require "file_utils"
require "process"
require "json"
require "../utils/xdg"
require "./language_loader"
require "./async_grammar_manager_v2"
require "../utils/timeout"
require "../utils/result"

module Chiasmus
  module Graph
    # Manages tree-sitter grammars: downloading, building, and caching
    class GrammarManager
      @@cache_dir : String?
      @@initialized = false

      # Grammar dependencies: language => [required_languages]
      GRAMMAR_DEPENDENCIES = {
        # TypeScript family depends on JavaScript
        "typescript" => ["javascript"],
        "tsx"        => ["javascript"],

        # C++ depends on C
        "cpp" => ["c"],

        # Some grammars might have other dependencies
        # Note: tree-sitter-c-sharp might not have dependencies
        # Note: tree-sitter-markdown depends on tree-sitter-markdown-inline
      }

      # Preferred installation methods for each language
      PREFERRED_METHODS = {
        # JavaScript/TypeScript family - best via npm
        "javascript" => :npm,
        "typescript" => :npm,
        "tsx"        => :npm,

        # Python, Rust, Crystal - good via git
        "python"  => :git,
        "rust"    => :git,
        "crystal" => :git,

        # C/C++ family - git
        "c"      => :git,
        "cpp"    => :git,
        "csharp" => :git,

        # Java family - git
        "java"   => :git,
        "kotlin" => :git,
        "scala"  => :git,

        # Ruby - git
        "ruby" => :git,

        # PHP - git
        "php" => :git,

        # Swift - git
        "swift" => :git,

        # Haskell - git
        "haskell" => :git,

        # Web technologies - git
        "html" => :git,
        "css"  => :git,

        # Shell - git
        "bash" => :git,

        # Configuration formats - git
        "json" => :git,
        "yaml" => :git,
        "toml" => :git,

        # Markdown - git
        "markdown" => :git,

        # SQL - git
        "sql" => :git,

        # Other languages - git
        "lua"    => :git,
        "dart"   => :git,
        "elixir" => :git,
        "erlang" => :git,
        "ocaml"  => :git,
        "perl"   => :git,
        "r"      => :git,
        "zig"    => :git,

        # Clojure - npm (WASM-based)
        "clojure" => :npm,
      }

      # Initialize the grammar manager
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        @@cache_dir = cache_dir || default_cache_dir
        begin
          Dir.mkdir_p(@@cache_dir.not_nil!)
          migrate_legacy_cache_if_needed
        rescue File::Error
          # Best effort only; async path will report actual availability later.
        end

        AsyncGrammarManagerV2.init(@@cache_dir)

        @@initialized = true
      end

      # Ensure a grammar is available, downloading/building if necessary
      def self.ensure_grammar(language : String, timeout_ms : Int32 = 120_000) : Bool
        init unless @@initialized

        ensure_channel = AsyncGrammarManagerV2.ensure_grammar_async(language, timeout_ms)
        result = Utils::Timeout.with_timeout_async(timeout_ms, ensure_channel)
        return false unless result

        result.success? && result.value == true
      end

      # Check if a grammar is available in the system
      def self.grammar_available?(language : String, timeout_ms : Int32 = 5_000) : Bool
        # Check if we can get a path to the grammar
        get_grammar_path(language, timeout_ms) != nil
      end

      # Get the path to a built grammar shared library
      def self.get_grammar_path(language : String, timeout_ms : Int32 = 5_000) : String?
        init unless @@initialized

        path_channel = AsyncGrammarManagerV2.get_grammar_path_async(language)
        result = Utils::Timeout.with_timeout_async(timeout_ms, path_channel)
        return nil unless result && result.success?

        result.value
      end

      private def self.default_cache_dir : String
        Utils::XDG.grammar_cache_dir
      end

      private def self.migrate_legacy_cache_if_needed
        legacy_dir = legacy_cache_dir
        return unless legacy_dir
        return unless Dir.exists?(legacy_dir)

        cache_dir = @@cache_dir.not_nil!
        return if same_path?(cache_dir, legacy_dir)

        Dir.children(legacy_dir).each do |entry|
          source = File.join(legacy_dir, entry)
          dest = File.join(cache_dir, entry)
          next if File.exists?(dest) || Dir.exists?(dest)

          FileUtils.cp_r(source, dest)
        end
      rescue ex
        # Treat migration as best-effort so parsing still works when the XDG
        # cache starts empty and no legacy cache is present.
        puts "Warning: failed to migrate legacy grammar cache: #{ex.message}"
      end

      private def self.legacy_cache_dir : String?
        {% if flag?(:darwin) %}
          File.join(Path.home.to_s, "Library", "Caches", "chiasmus", "grammars")
        {% else %}
          nil
        {% end %}
      end

      private def self.same_path?(left : String, right : String) : Bool
        File.expand_path(left) == File.expand_path(right)
      end

      private def self.check_tree_sitter_cli : Bool
        # Check if tree-sitter CLI is available
        result = Process.run("which", ["tree-sitter"], output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)

        unless result.success?
          puts "Warning: tree-sitter CLI not found."
          puts "Install with: npm install -g tree-sitter-cli"
          puts "Or build from source: https://tree-sitter.github.io/tree-sitter/creating-parsers#installation"
          return false
        end

        true
      end

      private def self.build_from_vendored_source(language : String) : Bool
        # Look for vendored grammar source
        source_dir = find_vendored_grammar_source(language)
        return false unless source_dir && Dir.exists?(source_dir)

        puts "  Found vendored source at: #{source_dir}"

        # Build the grammar
        build_grammar(source_dir, language)
      end

      private def self.find_vendored_grammar_source(language : String) : String?
        # Check our vendored grammars directory
        vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)

        # Try direct match
        grammar_dir = File.join(vendor_dir, "tree-sitter-#{language}")
        return grammar_dir if Dir.exists?(grammar_dir)

        # For TypeScript/TSX, check subdirectories
        if language == "typescript"
          ts_dir = File.join(vendor_dir, "tree-sitter-typescript", "typescript")
          return ts_dir if Dir.exists?(ts_dir)
        elsif language == "tsx"
          tsx_dir = File.join(vendor_dir, "tree-sitter-typescript", "tsx")
          return tsx_dir if Dir.exists?(tsx_dir)
        end

        # Try to find by scanning
        Dir.children(vendor_dir).each do |dir|
          full_path = File.join(vendor_dir, dir)
          next unless Dir.exists?(full_path)

          # Check if this directory contains the language we need
          if dir == "tree-sitter-typescript" && language.in?("typescript", "tsx")
            subdir = File.join(full_path, language)
            return subdir if Dir.exists?(subdir)
          elsif dir == "tree-sitter-#{language}"
            return full_path
          end
        end

        nil
      end

      private def self.build_grammar(source_dir : String, language : String) : Bool
        puts "  Building grammar for #{language} from #{source_dir}..."

        # Check for tree-sitter CLI
        unless check_tree_sitter_cli
          puts "  Cannot build without tree-sitter CLI"
          return false
        end

        # Check for C compiler
        unless system("which cc > /dev/null 2>&1") || system("which gcc > /dev/null 2>&1") || system("which clang > /dev/null 2>&1")
          puts "  C compiler not found. Install gcc or clang."
          return false
        end

        original_dir = Dir.current
        begin
          Dir.cd(source_dir)

          # Check for grammar.js in current directory or parent
          grammar_js = "grammar.js"
          unless File.exists?(grammar_js)
            # Try parent directory (for TypeScript/TSX)
            parent_dir = File.dirname(source_dir)
            parent_grammar_js = File.join(parent_dir, "grammar.js")
            if File.exists?(parent_grammar_js)
              puts "    Using grammar.js from parent directory"
              grammar_js = parent_grammar_js
            else
              puts "    grammar.js not found in #{source_dir} or parent"
              return false
            end
          end

          # Generate parser.c
          puts "    Generating parser..."
          unless system("tree-sitter generate #{grammar_js}")
            puts "    Failed to generate parser"
            return false
          end

          # Build shared library
          puts "    Building shared library..."
          ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
          output_file = "libtree-sitter-#{language}.#{ext}"

          # Find source files
          src_files = Dir.glob("src/*.c")
          if src_files.empty?
            puts "    No C source files found in src/"
            return false
          end

          # Build command
          build_cmd = "cc -shared -fPIC -I./src -o #{output_file} #{src_files.join(" ")}"
          puts "    Running: #{build_cmd}"

          unless system(build_cmd)
            puts "    Failed to build shared library"
            return false
          end

          # Install to cache directory
          # Use tree-sitter-{language} directory structure for repository compatibility
          ts_language_dir = File.join(@@cache_dir.not_nil!, "tree-sitter-#{language}")
          Dir.mkdir_p(ts_language_dir)

          # Copy .dylib/.so to the root
          dest_file = File.join(ts_language_dir, output_file)
          FileUtils.cp(output_file, dest_file)

          # Also copy src/ directory with grammar.json
          src_dir = File.join(ts_language_dir, "src")
          Dir.mkdir_p(src_dir)

          # Copy all .c files
          Dir.glob("src/*.c").each do |c_file|
            FileUtils.cp(c_file, File.join(src_dir, File.basename(c_file)))
          end

          # Copy grammar.json if it exists
          grammar_json = File.join(source_dir, "src", "grammar.json")
          if File.exists?(grammar_json)
            FileUtils.cp(grammar_json, File.join(src_dir, "grammar.json"))
          end

          puts "    Built and cached at: #{dest_file}"

          # Update tree-sitter config to include our cache directory
          update_tree_sitter_config(File.dirname(ts_language_dir))

          true
        rescue ex
          puts "    Error building grammar: #{ex.message}"
          false
        ensure
          Dir.cd(original_dir)
        end
      end

      private def self.download_and_build_from_github(language : String) : Bool
        puts "  Downloading #{language} grammar from GitHub..."

        # GitHub repository URL
        repo_url = "https://github.com/tree-sitter/tree-sitter-#{language}.git"

        # Download to cache directory
        cache_dir = File.join(@@cache_dir.not_nil!, "sources", language)
        Dir.mkdir_p(cache_dir)

        # Check if already downloaded
        if Dir.exists?(File.join(cache_dir, ".git"))
          puts "    Already downloaded, updating..."
          Dir.cd(cache_dir) do
            unless system("git pull")
              puts "    Failed to update repository"
              return false
            end
          end
        else
          puts "    Cloning #{repo_url}"
          unless system("git clone #{repo_url} #{cache_dir}")
            puts "    Failed to clone repository"
            return false
          end
        end

        # Build the downloaded grammar
        build_grammar(cache_dir, language)
      end

      private def self.install_via_npm(language : String) : Bool
        puts "  Installing #{language} grammar via npm..."

        # Check if npm is available
        unless system("which npm > /dev/null 2>&1")
          puts "    npm not found"
          return false
        end

        # npm package names for tree-sitter grammars
        package_map = {
          # JavaScript/TypeScript family
          "javascript" => "tree-sitter-javascript",
          "typescript" => "tree-sitter-typescript",
          "tsx"        => "tree-sitter-typescript",

          # Other languages available on npm
          "c"        => "tree-sitter-c",
          "cpp"      => "tree-sitter-cpp",
          "csharp"   => "tree-sitter-c-sharp",
          "python"   => "tree-sitter-python",
          "go"       => "tree-sitter-go",
          "java"     => "tree-sitter-java",
          "kotlin"   => "tree-sitter-kotlin",
          "ruby"     => "tree-sitter-ruby",
          "rust"     => "tree-sitter-rust",
          "php"      => "tree-sitter-php",
          "swift"    => "tree-sitter-swift",
          "haskell"  => "tree-sitter-haskell",
          "html"     => "tree-sitter-html",
          "css"      => "tree-sitter-css",
          "bash"     => "tree-sitter-bash",
          "json"     => "tree-sitter-json",
          "yaml"     => "tree-sitter-yaml",
          "toml"     => "tree-sitter-toml",
          "markdown" => "tree-sitter-markdown",
          "sql"      => "tree-sitter-sql",
          "lua"      => "tree-sitter-lua",
          "dart"     => "tree-sitter-dart",
          "elixir"   => "tree-sitter-elixir",
          "erlang"   => "tree-sitter-erlang",
          "ocaml"    => "tree-sitter-ocaml",
          "perl"     => "tree-sitter-perl",
          "r"        => "tree-sitter-r",
          "zig"      => "tree-sitter-zig",
          "clojure"  => "@yogthos/tree-sitter-clojure",
          "crystal"  => "tree-sitter-crystal",
          "scala"    => "tree-sitter-scala",
        }

        package = package_map[language]?
        return false unless package

        # Install directory - use a shared directory for npm packages
        # This allows dependencies to be shared between languages
        install_dir = File.join(@@cache_dir.not_nil!, "npm")
        Dir.mkdir_p(install_dir)

        # Install package
        Dir.cd(install_dir) do
          puts "    Installing #{package}..."

          # Check if package is already installed
          node_modules = File.join(install_dir, "node_modules")
          package_dir = File.join(node_modules, package)

          if Dir.exists?(package_dir)
            puts "    Package already installed"
          else
            # Initialize package.json if it doesn't exist
            unless File.exists?("package.json")
              unless system("npm init -y > /dev/null 2>&1")
                puts "    Failed to initialize npm project"
                return false
              end
            end

            # Install the package
            unless system("npm install #{package} > /dev/null 2>&1")
              puts "    Failed to install #{package}"
              return false
            end
          end

          # For TypeScript/TSX, need to look in subdirectories
          if language == "typescript"
            source_dir = File.join(package_dir, "typescript")
          elsif language == "tsx"
            source_dir = File.join(package_dir, "tsx")
          else
            source_dir = package_dir
          end

          if Dir.exists?(source_dir)
            # For TypeScript/TSX, we need to build from the npm root directory
            # because grammar.js references JavaScript grammar in node_modules
            if language.in?("typescript", "tsx")
              # Build from the npm directory root where node_modules is available
              if build_grammar_from_npm_root(install_dir, source_dir, language)
                # Also ensure JavaScript is built
                js_package_dir = File.join(node_modules, "tree-sitter-javascript")
                if Dir.exists?(js_package_dir)
                  puts "    Building JavaScript dependency..."
                  build_grammar(js_package_dir, "javascript")
                end
                return true
              end
            else
              # Build from the npm-installed source
              if build_grammar(source_dir, language)
                return true
              end
            end
          end
        end

        false
      end

      private def self.build_grammar_from_npm_root(npm_root : String, source_dir : String, language : String) : Bool
        puts "    Building #{language} from npm root #{npm_root}..."

        # Check for tree-sitter CLI
        unless check_tree_sitter_cli
          puts "    Cannot build without tree-sitter CLI"
          return false
        end

        # Check for C compiler
        unless system("which cc > /dev/null 2>&1") || system("which gcc > /dev/null 2>&1") || system("which clang > /dev/null 2>&1")
          puts "    C compiler not found. Install gcc or clang."
          return false
        end

        original_dir = Dir.current
        begin
          # Change to npm root where node_modules is available
          Dir.cd(npm_root)

          # Build from the source directory relative to npm root
          relative_source_dir = Path.new(source_dir).relative_to(npm_root)

          # Generate parser.c
          puts "    Generating parser..."
          unless system("tree-sitter generate #{relative_source_dir}/grammar.js")
            puts "    Failed to generate parser"
            return false
          end

          # Change to source directory for building
          Dir.cd(source_dir)

          # Build shared library
          puts "    Building shared library..."
          ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
          output_file = "libtree-sitter-#{language}.#{ext}"

          # Find source files
          src_files = Dir.glob("src/*.c")
          if src_files.empty?
            puts "    No C source files found in src/"
            return false
          end

          # Build command
          build_cmd = "cc -shared -fPIC -I./src -o #{output_file} #{src_files.join(" ")}"
          puts "    Running: #{build_cmd}"

          unless system(build_cmd)
            puts "    Failed to build shared library"
            return false
          end

          # Install to cache directory
          # Use tree-sitter-{language} directory structure for repository compatibility
          ts_language_dir = File.join(@@cache_dir.not_nil!, "tree-sitter-#{language}")
          Dir.mkdir_p(ts_language_dir)

          # Copy .dylib/.so to the root
          dest_file = File.join(ts_language_dir, output_file)
          FileUtils.cp(output_file, dest_file)

          # Also copy src/ directory with grammar.json
          src_dir = File.join(ts_language_dir, "src")
          Dir.mkdir_p(src_dir)

          # Copy all .c files
          Dir.glob("src/*.c").each do |c_file|
            FileUtils.cp(c_file, File.join(src_dir, File.basename(c_file)))
          end

          # Copy grammar.json if it exists
          grammar_json = File.join(source_dir, "src", "grammar.json")
          if File.exists?(grammar_json)
            FileUtils.cp(grammar_json, File.join(src_dir, "grammar.json"))
          end

          puts "    Built and cached at: #{dest_file}"

          # Update tree-sitter config to include our cache directory
          update_tree_sitter_config(File.dirname(ts_language_dir))

          true
        rescue ex
          puts "    Error building grammar: #{ex.message}"
          false
        ensure
          Dir.cd(original_dir)
        end
      end

      private def self.update_tree_sitter_config(grammar_dir : String)
        config_dir = get_tree_sitter_config_dir
        tree_sitter_config_dir = File.join(config_dir, "tree-sitter")
        Dir.mkdir_p(tree_sitter_config_dir)

        config_file = File.join(tree_sitter_config_dir, "config.json")

        parser_dirs = [] of String

        # Read existing config if it exists
        if File.exists?(config_file)
          begin
            config = File.read(config_file)
            parsed = JSON.parse(config)
            if dirs = parsed["parser-directories"]?.try(&.as_a)
              parser_dirs = dirs.map(&.as_s)
            end
          rescue
            # If config is invalid, start fresh
          end
        end

        # Add our grammar directory if not already present
        return if parser_dirs.includes?(grammar_dir)
        parser_dirs << grammar_dir

        # Write updated config
        config = {
          "parser-directories" => parser_dirs,
        }

        File.write(config_file, config.to_json)
        puts "    Updated tree-sitter config at #{config_file}"
      end

      private def self.get_tree_sitter_config_dir : String
        Utils::XDG.tree_sitter_config_dir
      end

      # Get list of languages we can potentially support
      def self.supported_language_list : Array(String)
        # Common programming languages with tree-sitter grammars
        [
          "c", "cpp", "csharp", "go", "java", "javascript", "typescript", "tsx",
          "python", "ruby", "rust", "php", "scala", "swift", "kotlin", "bash",
          "lua", "html", "css", "json", "yaml", "toml", "dockerfile", "make",
          "cmake", "sql", "markdown", "latex", "haskell", "ocaml", "elixir",
          "clojure", "erlang", "perl", "r", "dart", "elm", "pascal", "fortran",
        ]
      end
    end
  end
end
