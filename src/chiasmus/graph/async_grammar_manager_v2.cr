require "file_utils"
require "process"
require "json"
require "tree_sitter"
require "./grammar_operations"
require "./language_loader"
require "../utils/xdg"
require "../utils/timeout"
require "../utils/result"

module Chiasmus
  module Graph
    # Fully async grammar manager using non-blocking operations
    class AsyncGrammarManagerV2
      @@instance : AsyncGrammarManagerV2?
      @@cache_dir : String?
      @@initialized = false

      # Grammar dependencies and preferred methods (copied from GrammarManager)
      GRAMMAR_DEPENDENCIES = {
        "typescript" => ["javascript"],
        "tsx"        => ["javascript"],
        "cpp"        => ["c"],
      }

      PREFERRED_METHODS = {
        "javascript" => :npm,
        "typescript" => :npm,
        "tsx"        => :npm,
        "clojure"    => :npm,
        "python"     => :git,
        "rust"       => :git,
        "crystal"    => :git,
        "c"          => :git,
        "cpp"        => :git,
        "csharp"     => :git,
        "java"       => :git,
        "kotlin"     => :git,
        "scala"      => :git,
        "ruby"       => :git,
        "php"        => :git,
        "swift"      => :git,
        "haskell"    => :git,
        "html"       => :git,
        "css"        => :git,
        "bash"       => :git,
        "json"       => :git,
        "yaml"       => :git,
        "toml"       => :git,
        "markdown"   => :git,
        "sql"        => :git,
        "lua"        => :git,
        "dart"       => :git,
        "elixir"     => :git,
        "erlang"     => :git,
        "ocaml"      => :git,
        "perl"       => :git,
        "r"          => :git,
        "zig"        => :git,
      }

      # Singleton instance
      def self.instance : AsyncGrammarManagerV2
        @@instance ||= new
      end

      # Initialize with cache directory
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        @@cache_dir = cache_dir || default_cache_dir
        begin
          Dir.mkdir_p(@@cache_dir.not_nil!)
          migrate_legacy_cache_if_needed
        rescue File::Error
          # Sandboxed environments may not permit cache directory creation.
          # Keep the configured path and let later operations fail gracefully.
        end

        @@initialized = true
      end

      # Ensure a grammar is available (fully async)
      def self.ensure_grammar_async(language : String, timeout_ms : Int32 = 120_000) : Channel(Utils::BoolResult)
        init unless @@initialized

        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            # Check if already available with timeout
            available_channel = grammar_available_async(language)
            available_result = Utils::Timeout.with_timeout_async(5_000, available_channel)

            unless available_result
              channel.send(Utils::BoolResult.failure(
                "Timeout checking if grammar is available",
                {"language" => language}
              ))
              next
            end

            if available_result.success? && available_result.value == true
              channel.send(Utils::BoolResult.success)
              next
            end

            # Handle dependencies first
            if deps = GRAMMAR_DEPENDENCIES[language]?
              deps_success = ensure_dependencies_async(deps)
              unless deps_success
                channel.send(Utils::BoolResult.failure(
                  "Failed to ensure dependencies",
                  {"language" => language, "dependencies" => deps.join(", ")}
                ))
                next
              end
            end

            # Try to make grammar available with timeout
            make_channel = make_grammar_available_async(language)
            make_result = Utils::Timeout.with_timeout_async(timeout_ms, make_channel)

            unless make_result
              channel.send(Utils::BoolResult.failure(
                "Timeout making grammar available",
                {"language" => language, "timeout_ms" => timeout_ms.to_s}
              ))
              next
            end

            channel.send(make_result)
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Unexpected error ensuring grammar: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Check if grammar is available (async)
      def self.grammar_available_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            # Check via tree-sitter repository
            if TreeSitter::Repository.language_names.includes?(language)
              channel.send(Utils::BoolResult.success)
              next
            end

            # Check our cache
            if cache_dir = @@cache_dir
              available = grammar_cache_paths(language, cache_dir).any? do |so_path|
                exists_channel = GrammarOperations.file_exists_async(so_path)
                Utils::Timeout.with_timeout_async(5_000, exists_channel) == true
              end

              if available
                channel.send(Utils::BoolResult.success)
              else
                channel.send(Utils::BoolResult.new(value: false))
              end
            else
              channel.send(Utils::BoolResult.failure(
                "Cache directory not initialized",
                {"language" => language}
              ))
            end
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error checking grammar availability: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Get grammar path (async)
      def self.get_grammar_path_async(language : String) : Channel(Utils::StringResult)
        channel = Channel(Utils::StringResult).new

        spawn do
          begin
            # Check tree-sitter repository first
            language_paths = LanguageLoader.repository_language_paths
            if path = language_paths[language]?
              ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
              so_path = path.join("libtree-sitter-#{language}.#{ext}")

              exists_channel = GrammarOperations.file_exists_async(so_path.to_s)
              exists_result = Utils::Timeout.with_timeout_async(5_000, exists_channel)

              if exists_result == true
                channel.send(Utils::StringResult.success(so_path.to_s))
                next
              end
            end

            # Check cache
            if cache_dir = @@cache_dir
              found_path = grammar_cache_paths(language, cache_dir).find do |so_path|
                exists_channel = GrammarOperations.file_exists_async(so_path)
                Utils::Timeout.with_timeout_async(5_000, exists_channel) == true
              end

              if found_path
                channel.send(Utils::StringResult.success(found_path))
              else
                channel.send(Utils::StringResult.failure(
                  "Grammar not found in cache",
                  {"language" => language, "cache_dir" => cache_dir}
                ))
              end
            else
              channel.send(Utils::StringResult.failure(
                "Cache directory not initialized",
                {"language" => language}
              ))
            end
          rescue ex
            channel.send(Utils::StringResult.failure(
              "Error getting grammar path: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Make a grammar available (main async logic)
      private def self.make_grammar_available_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            # Try preferred method first
            if preferred_method = PREFERRED_METHODS[language]?
              case preferred_method
              when :npm
                npm_channel = install_via_npm_async(language)
                npm_result = Utils::Timeout.with_timeout_async(60_000, npm_channel)
                if npm_result == true
                  channel.send(Utils::BoolResult.success)
                  next
                end
              when :git
                git_channel = download_and_build_from_github_async(language)
                git_result = Utils::Timeout.with_timeout_async(60_000, git_channel)
                if git_result == true
                  channel.send(Utils::BoolResult.success)
                  next
                end
              end
            end

            # Fallback: try all methods sequentially to avoid concurrent writes to
            # the same grammar/cache directories.
            vendor_result = Utils::Timeout.with_timeout_async(30_000, build_from_vendored_source_async(language))
            if vendor_result == true
              channel.send(Utils::BoolResult.success)
              next
            end

            npm_result = Utils::Timeout.with_timeout_async(30_000, install_via_npm_async(language))
            if npm_result == true
              channel.send(Utils::BoolResult.success)
              next
            end

            git_result = Utils::Timeout.with_timeout_async(30_000, download_and_build_from_github_async(language))
            if git_result == true
              channel.send(Utils::BoolResult.success)
            else
              # All methods failed
              channel.send(Utils::BoolResult.failure(
                "All installation methods failed for language",
                {"language" => language}
              ))
            end
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Unexpected error making grammar available: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Install via npm (async)
      private def self.install_via_npm_async(language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          # npm package map
          package_map = {
            "javascript" => "tree-sitter-javascript",
            "typescript" => "tree-sitter-typescript",
            "tsx"        => "tree-sitter-typescript",
            "c"          => "tree-sitter-c",
            "cpp"        => "tree-sitter-cpp",
            "csharp"     => "tree-sitter-c-sharp",
            "python"     => "tree-sitter-python",
            "go"         => "tree-sitter-go",
            "java"       => "tree-sitter-java",
            "kotlin"     => "tree-sitter-kotlin",
            "ruby"       => "tree-sitter-ruby",
            "rust"       => "tree-sitter-rust",
            "php"        => "tree-sitter-php",
            "swift"      => "tree-sitter-swift",
            "haskell"    => "tree-sitter-haskell",
            "html"       => "tree-sitter-html",
            "css"        => "tree-sitter-css",
            "bash"       => "tree-sitter-bash",
            "json"       => "tree-sitter-json",
            "yaml"       => "tree-sitter-yaml",
            "toml"       => "tree-sitter-toml",
            "markdown"   => "tree-sitter-markdown",
            "sql"        => "tree-sitter-sql",
            "lua"        => "tree-sitter-lua",
            "dart"       => "tree-sitter-dart",
            "elixir"     => "tree-sitter-elixir",
            "erlang"     => "tree-sitter-erlang",
            "ocaml"      => "tree-sitter-ocaml",
            "perl"       => "tree-sitter-perl",
            "r"          => "tree-sitter-r",
            "zig"        => "tree-sitter-zig",
            "clojure"    => "@yogthos/tree-sitter-clojure",
            "crystal"    => "tree-sitter-crystal",
            "scala"      => "tree-sitter-scala",
          }

          package = package_map[language]?
          unless package
            channel.send(false)
            next
          end

          # Check if npm is available
          npm_check = GrammarOperations.run_command_async("which", ["npm"])
          success, _, _ = npm_check.receive
          unless success
            channel.send(false)
            next
          end

          # Install directory
          install_dir = File.join(@@cache_dir.not_nil!, "npm")
          create_dir_channel = GrammarOperations.create_dir_async(install_dir)
          unless create_dir_channel.receive
            channel.send(false)
            next
          end

          # Install package
          install_channel = GrammarOperations.npm_install_async(package, install_dir)
          unless install_channel.receive
            channel.send(false)
            next
          end

          # Find and build the grammar
          node_modules = File.join(install_dir, "node_modules")
          package_dir = File.join(node_modules, package)

          # For TypeScript/TSX, need to look in subdirectories
          source_dir = if language == "typescript"
                         File.join(package_dir, "typescript")
                       elsif language == "tsx"
                         File.join(package_dir, "tsx")
                       else
                         package_dir
                       end

          # Build the grammar
          build_success = build_grammar_async(source_dir, language).receive
          channel.send(build_success)
        end

        channel
      end

      # Download and build from GitHub (async)
      private def self.download_and_build_from_github_async(language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          cache_dir = File.join(@@cache_dir.not_nil!, "sources", language)

          # Check if already downloaded
          git_dir = File.join(cache_dir, ".git")
          exists_channel = GrammarOperations.dir_exists_async(git_dir)

          if exists_channel.receive
            # Update existing
            update_channel = GrammarOperations.git_pull_async(cache_dir)
            unless update_channel.receive
              channel.send(false)
              next
            end
          else
            # Clone new
            repo_url = "https://github.com/tree-sitter/tree-sitter-#{language}.git"
            clone_channel = GrammarOperations.git_clone_async(repo_url, cache_dir)
            unless clone_channel.receive
              channel.send(false)
              next
            end
          end

          # Build the grammar
          build_success = build_grammar_async(cache_dir, language).receive
          channel.send(build_success)
        end

        channel
      end

      # Build from vendored source (async)
      private def self.build_from_vendored_source_async(language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          # Look for vendored source
          vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)

          # Try to find the grammar source
          source_dir = find_vendored_grammar_source(vendor_dir, language)
          unless source_dir
            channel.send(false)
            next
          end

          # Build the grammar
          build_success = build_grammar_async(source_dir, language).receive
          channel.send(build_success)
        end

        channel
      end

      # Build grammar from source directory (async)
      private def self.build_grammar_async(source_dir : String, language : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          # Check for tree-sitter CLI
          ts_check = GrammarOperations.check_tree_sitter_cli_async
          unless ts_check.receive
            channel.send(false)
            next
          end

          # Check for C compiler
          cc_check = GrammarOperations.run_command_async("which", ["cc"])
          gcc_check = GrammarOperations.run_command_async("which", ["gcc"])
          clang_check = GrammarOperations.run_command_async("which", ["clang"])

          cc_success, _, _ = cc_check.receive
          gcc_success, _, _ = gcc_check.receive
          clang_success, _, _ = clang_check.receive

          unless cc_success || gcc_success || clang_success
            channel.send(false)
            next
          end

          # Find grammar.js
          grammar_js = File.join(source_dir, "grammar.js")
          exists_channel = GrammarOperations.file_exists_async(grammar_js)
          unless exists_channel.receive
            # Try parent directory (for TypeScript/TSX)
            parent_dir = File.dirname(source_dir)
            parent_grammar_js = File.join(parent_dir, "grammar.js")
            exists_channel = GrammarOperations.file_exists_async(parent_grammar_js)
            if exists_channel.receive
              grammar_js = parent_grammar_js
            else
              channel.send(false)
              next
            end
          end

          # Generate parser
          generate_channel = GrammarOperations.tree_sitter_generate_async(grammar_js)
          unless generate_channel.receive
            channel.send(false)
            next
          end

          # Compile shared library
          compile_channel = GrammarOperations.compile_shared_library_async(source_dir, language)
          compile_success, so_path_or_error = compile_channel.receive

          unless compile_success
            channel.send(false)
            next
          end

          so_path = so_path_or_error.not_nil!

          # Install to cache
          ts_language_dir = File.join(@@cache_dir.not_nil!, "tree-sitter-#{language}")
          create_dir_channel = GrammarOperations.create_dir_async(ts_language_dir)
          unless create_dir_channel.receive
            channel.send(false)
            next
          end

          dest_file = File.join(ts_language_dir, File.basename(so_path))
          copy_channel = GrammarOperations.copy_file_async(so_path, dest_file)
          unless copy_channel.receive
            channel.send(false)
            next
          end

          # Copy src directory
          src_dir = File.join(ts_language_dir, "src")
          create_dir_channel = GrammarOperations.create_dir_async(src_dir)
          unless create_dir_channel.receive
            channel.send(false)
            next
          end

          # Copy .c files
          source_src_dir = File.join(source_dir, "src")
          exists_channel = GrammarOperations.dir_exists_async(source_src_dir)
          if exists_channel.receive
            Dir.children(source_src_dir).each do |file|
              if file.ends_with?(".c") || file == "grammar.json"
                src_file = File.join(source_src_dir, file)
                dest_file = File.join(src_dir, file)
                GrammarOperations.copy_file_async(src_file, dest_file).receive
              end
            end
          end

          # Update tree-sitter config
          update_config_async(File.dirname(ts_language_dir))

          channel.send(true)
        end

        channel
      end

      # Update tree-sitter config (async)
      private def self.update_config_async(grammar_dir : String)
        spawn do
          config_dir = get_tree_sitter_config_dir
          tree_sitter_config_dir = File.join(config_dir, "tree-sitter")
          GrammarOperations.create_dir_async(tree_sitter_config_dir).receive

          config_file = File.join(tree_sitter_config_dir, "config.json")

          parser_dirs = [] of String

          # Read existing config if it exists
          exists_channel = GrammarOperations.file_exists_async(config_file)
          if exists_channel.receive
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
          unless parser_dirs.includes?(grammar_dir)
            parser_dirs << grammar_dir

            # Write updated config
            config = {
              "parser-directories" => parser_dirs,
            }

            File.write(config_file, config.to_json)
          end
        end
      end

      # Helper methods
      private def self.find_vendored_grammar_source(vendor_dir : String, language : String) : String?
        # Try direct match
        grammar_dir = File.join(vendor_dir, "tree-sitter-#{language}")
        exists_channel = GrammarOperations.dir_exists_async(grammar_dir)
        return grammar_dir if exists_channel.receive

        # For TypeScript/TSX, check subdirectories
        if language == "typescript"
          ts_dir = File.join(vendor_dir, "tree-sitter-typescript", "typescript")
          exists_channel = GrammarOperations.dir_exists_async(ts_dir)
          return ts_dir if exists_channel.receive
        elsif language == "tsx"
          tsx_dir = File.join(vendor_dir, "tree-sitter-typescript", "tsx")
          exists_channel = GrammarOperations.dir_exists_async(tsx_dir)
          return tsx_dir if exists_channel.receive
        end

        nil
      end

      private def self.ensure_dependencies_async(dependencies : Array(String)) : Bool
        dependencies.each do |dep|
          ensure_channel = ensure_grammar_async(dep)
          ensure_result = Utils::Timeout.with_timeout_async(30_000, ensure_channel)
          unless ensure_result && ensure_result.success? && ensure_result.value == true
            return false
          end
        end
        true
      end

      private def self.default_cache_dir : String
        Utils::XDG.grammar_cache_dir
      end

      private def self.grammar_cache_paths(language : String, cache_dir : String) : Array(String)
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        [
          File.join(cache_dir, language, "libtree-sitter-#{language}.#{ext}"),
          File.join(cache_dir, "tree-sitter-#{language}", "libtree-sitter-#{language}.#{ext}"),
        ]
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
      rescue File::Error
        nil
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

      private def self.get_tree_sitter_config_dir : String
        Utils::XDG.tree_sitter_config_dir
      end
    end
  end
end
