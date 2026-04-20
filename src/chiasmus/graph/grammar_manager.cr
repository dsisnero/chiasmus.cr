require "file_utils"
require "process"
require "json"
require "tree_sitter"
require "./grammar_operations"
require "./language_loader"
require "./language_registry"
require "./grammar_metadata"
require "./embedded_grammars"
require "../utils/xdg"
require "../utils/timeout"
require "../utils/result"

module Chiasmus
  module Graph
    # Single, non-blocking async GrammarManager using Crystal/Go-style concurrency
    # All operations are async by default, using fibers and channels
    class GrammarManager
      @@instance : GrammarManager?
      @@cache_dir : String?
      @@initialized = false
      @@mutex = Mutex.new

      # Singleton instance
      def self.instance : GrammarManager
        @@instance ||= new
      end

      # Initialize with cache directory (async-safe)
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        @@mutex.synchronize do
          return if @@initialized

          @@cache_dir = cache_dir || default_cache_dir
          if cache_dir = @@cache_dir
            begin
              Dir.mkdir_p(cache_dir)
              migrate_legacy_cache_if_needed

              # Extract embedded grammars if available
              extract_embedded_grammars(cache_dir)
            rescue File::Error
              # Sandboxed environments may not permit cache directory creation.
              # Keep the configured path and let later operations fail gracefully.
            end
          end

          # Auto-create metadata for existing vendor grammars
          auto_create_vendor_metadata

          @@initialized = true
        end
      end

      # Check if a grammar is available (async, non-blocking)
      def grammar_available_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            # Check via tree-sitter repository (fast path)
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

      # Get grammar path (async, non-blocking)
      def get_grammar_path_async(language : String) : Channel(Utils::StringResult)
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
              found_path = grammar_cache_paths(language, cache_dir).find do |grammar_path|
                exists_channel = GrammarOperations.file_exists_async(grammar_path)
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

      # Ensure a grammar is available (async, non-blocking)
      # This is the main entry point for grammar acquisition
      def ensure_grammar_async(language : String, timeout_ms : Int32 = 120_000) : Channel(Utils::BoolResult)
        self.class.init

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

            # Handle dependencies first (async, concurrent)
            deps = LanguageRegistry.dependencies(language)
            if !deps.empty?
              deps_success = ensure_dependencies_async(deps)
              unless deps_success
                channel.send(Utils::BoolResult.failure(
                  "Failed to ensure dependencies",
                  {"language" => language, "dependencies" => deps.join(", ")}
                ))
                next
              end
            end

            # Make the grammar available (async)
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
              "Error ensuring grammar: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Clear cache (async, non-blocking)
      def clear_cache_async : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            cache_dir = @@cache_dir
            unless cache_dir && Dir.exists?(cache_dir)
              channel.send(Utils::BoolResult.failure(
                "Cache directory does not exist",
                {"cache_dir" => cache_dir.to_s}
              ))
              next
            end

            # Remove all .dylib/.so files
            ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
            Dir.glob(File.join(cache_dir, "**", "*.#{ext}")).each do |lib_file|
              File.delete(lib_file)
            end

            # Remove empty directories
            Dir.children(cache_dir).each do |dir|
              dir_path = File.join(cache_dir, dir)
              if Dir.exists?(dir_path) && Dir.empty?(dir_path)
                Dir.delete(dir_path)
              end
            end

            channel.send(Utils::BoolResult.success)
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error clearing cache: #{ex.message}",
              {"exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Get cache directory
      def cache_dir : String?
        @@cache_dir
      end

      # Sync wrapper for ensure_grammar_async
      def ensure_grammar(language : String, timeout_ms : Int32 = 120_000) : Bool
        channel = ensure_grammar_async(language, timeout_ms)
        result = Utils::Timeout.with_timeout_async(timeout_ms, channel)
        result ? result.success? && result.value == true : false
      end

      # Sync wrapper for get_grammar_path_async
      def get_grammar_path(language : String) : String?
        channel = get_grammar_path_async(language)
        result = Utils::Timeout.with_timeout_async(5_000, channel)
        result && result.success? ? result.value : nil
      end

      # Sync wrapper for grammar_available_async
      def grammar_available?(language : String) : Bool
        channel = grammar_available_async(language)
        result = Utils::Timeout.with_timeout_async(5_000, channel)
        result ? result.success? && result.value == true : false
      end

      # Class method wrappers for convenience
      def self.ensure_grammar(language : String, timeout_ms : Int32 = 120_000) : Bool
        instance.ensure_grammar(language, timeout_ms)
      end

      def self.get_grammar_path(language : String) : String?
        instance.get_grammar_path(language)
      end

      def self.grammar_available?(language : String) : Bool
        instance.grammar_available?(language)
      end

      # Test helper to reset state
      def self.test_reset(cache_dir : String? = nil)
        @@mutex.synchronize do
          @@instance = nil
          @@cache_dir = cache_dir
          @@initialized = false
        end
      end

      # Private methods

      private def self.default_cache_dir : String
        Utils::XDG.grammar_cache_dir
      end

      # Extract embedded grammars to cache directory
      private def self.extract_embedded_grammars(cache_dir : String)
        # Only extract if we have embedded grammars
        return unless EmbeddedGrammars.embedded?("python") # Check if any grammar is embedded

        puts "[GrammarManager] Extracting embedded grammars to cache..." if ENV["CHIASMUS_DEBUG"]?

        # Try to extract all embedded grammars
        # If extraction fails, we'll fall back to downloading/building
        begin
          EmbeddedGrammars.extract_all_to_cache(cache_dir)
        rescue ex
          # Silently fail - we'll download/build grammars as needed
          puts "[GrammarManager] Failed to extract embedded grammars: #{ex.message}" if ENV["CHIASMUS_DEBUG"]?
        end
      end

      private def self.migrate_legacy_cache_if_needed
        legacy_dir = legacy_cache_dir
        return unless legacy_dir
        return unless Dir.exists?(legacy_dir)

        cache_dir = @@cache_dir
        return unless cache_dir
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

      private def grammar_cache_paths(language : String, cache_dir : String) : Array(String)
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"

        paths = [] of String

        # 1. Check in distribution grammars directory (relative to binary)
        if binary_dir = get_binary_dir
          dist_grammar_dir = File.join(binary_dir, "grammars")
          paths << File.join(dist_grammar_dir, lib_name)
        end

        # 2. Check in cache directory
        paths << File.join(cache_dir, language, lib_name)
        paths << File.join(cache_dir, "tree-sitter-#{language}", lib_name)

        paths
      end

      # Get directory containing the binary
      private def get_binary_dir : String?
        # Try to get the directory of the running executable
        Process.executable_path.try { |path| File.dirname(path) }
      end

      # Ensure multiple dependencies concurrently (async)
      private def ensure_dependencies_async(dependencies : Array(String)) : Bool
        return true if dependencies.empty?

        channels = dependencies.map do |dep|
          ensure_grammar_async(dep, 60_000)
        end

        success = true
        channels.each do |channel|
          result = Utils::Timeout.with_timeout_async(60_000, channel)
          unless result && result.success? && result.value == true
            success = false
            break
          end
        end

        success
      end

      # Make a grammar available (main async logic)
      private def make_grammar_available_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            channel.send(install_grammar(language))
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error making grammar available: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      private def install_grammar(language : String) : Utils::BoolResult
        preferred_method = LanguageRegistry.preferred_method(language)
        if preferred_method && install_with_method(language, preferred_method, 90_000)
          return Utils::BoolResult.success
        end

        return Utils::BoolResult.success if install_with_fallbacks(language)

        Utils::BoolResult.failure(
          "Failed to install grammar via any method",
          {"language" => language}
        )
      end

      private def install_with_fallbacks(language : String) : Bool
        install_with_method(language, :npm, 60_000) || install_with_method(language, :git, 60_000)
      end

      private def install_with_method(language : String, method : Symbol, timeout_ms : Int32) : Bool
        channel = case method
                  when :npm then install_via_npm_async(language)
                  when :git then install_via_git_async(language)
                  else           return false
                  end

        successful_result?(Utils::Timeout.with_timeout_async(timeout_ms, channel))
      end

      private def successful_result?(result : Utils::BoolResult?) : Bool
        return false unless result

        result.success? && result.value == true
      end

      # Install via npm (async)
      private def install_via_npm_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            package_name = LanguageRegistry.package_name(language)
            unless package_name
              channel.send(Utils::BoolResult.failure(
                "No package name configured for language",
                {"language" => language}
              ))
              next
            end

            # Create temp directory
            temp_dir = File.join(Dir.tempdir, "chiasmus-npm-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)

            # Run npm install
            output = IO::Memory.new
            error = IO::Memory.new
            status = Process.run("npm", ["install", package_name],
              output: output,
              error: error
            )

            unless status.success?
              channel.send(Utils::BoolResult.failure(
                "npm install failed",
                {"language" => language, "package" => package_name, "error" => error.to_s}
              ))
              next
            end

            # Find and copy the grammar
            node_modules_path = File.join(temp_dir, "node_modules")
            if Dir.exists?(node_modules_path)
              # Look for the grammar file
              grammar_found = copy_grammar_from_node_modules(language, node_modules_path, package_name)

              if grammar_found
                # Try to get package version from package.json
                version = nil
                package_json_path = File.join(node_modules_path, package_name, "package.json")
                if File.exists?(package_json_path)
                  begin
                    package_data = JSON.parse(File.read(package_json_path))
                    version = package_data["version"]?.try(&.as_s)
                  rescue
                    # Ignore errors
                  end
                end

                # Create metadata
                if cache_dir = @@cache_dir
                  cache_lib_dir = File.join(cache_dir, language)
                  metadata = GrammarMetadata.new(
                    url: "https://registry.npmjs.org/#{package_name}",
                    type: "npm",
                    version: version,
                    package_name: package_name,
                    language: language,
                    installed_at: Time.utc,
                    last_updated: Time.utc
                  )

                  GrammarMetadataStore.save(cache_lib_dir, metadata)
                end

                channel.send(Utils::BoolResult.success)
              else
                channel.send(Utils::BoolResult.failure(
                  "Grammar not found in npm package",
                  {"language" => language, "package" => package_name, "path" => node_modules_path}
                ))
              end
            else
              channel.send(Utils::BoolResult.failure(
                "node_modules not created",
                {"language" => language, "package" => package_name}
              ))
            end

            # Cleanup
            FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error installing via npm: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Install via git (async)
      private def install_via_git_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            package_name = LanguageRegistry.package_name(language)
            unless package_name
              channel.send(Utils::BoolResult.failure(
                "No package name configured for language",
                {"language" => language}
              ))
              next
            end

            # Create temp directory
            temp_dir = File.join(Dir.tempdir, "chiasmus-git-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)

            # Clone and build
            Dir.cd(temp_dir) do
              # Clone repository
              repo_url = "https://github.com/tree-sitter/#{package_name}.git"
              output = IO::Memory.new
              error = IO::Memory.new
              status = Process.run("git", ["clone", "--depth", "1", repo_url, "."],
                output: output,
                error: error
              )

              unless status.success?
                channel.send(Utils::BoolResult.failure(
                  "git clone failed",
                  {"language" => language, "repo" => repo_url, "error" => error.to_s}
                ))
                next
              end

              # Build the grammar
              build_result = build_grammar_async(language, temp_dir)

              if build_result
                # Try to get commit hash
                commit_hash = nil
                commit_output = IO::Memory.new
                commit_error = IO::Memory.new
                commit_result = Process.run("git", ["rev-parse", "HEAD"],
                  output: commit_output,
                  error: commit_error
                )
                if commit_result.success?
                  commit_hash = commit_output.to_s.strip
                end

                # Create metadata
                if cache_dir = @@cache_dir
                  cache_lib_dir = File.join(cache_dir, language)
                  metadata = GrammarMetadata.new(
                    url: repo_url,
                    type: "git",
                    commit_hash: commit_hash,
                    package_name: package_name,
                    language: language,
                    installed_at: Time.utc,
                    last_updated: Time.utc
                  )

                  GrammarMetadataStore.save(cache_lib_dir, metadata)
                end

                channel.send(Utils::BoolResult.success)
              else
                channel.send(Utils::BoolResult.failure(
                  "Failed to build grammar",
                  {"language" => language, "path" => temp_dir}
                ))
              end
            end

            # Cleanup
            FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error installing via git: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Build grammar (async)
      private def build_grammar_async(language : String, source_dir : String) : Bool
        Dir.cd(source_dir) do
          # Check if tree-sitter CLI is available
          unless system("which tree-sitter > /dev/null 2>&1")
            return false
          end

          # Generate parser
          generate_output = IO::Memory.new
          generate_error = IO::Memory.new
          generate_status = Process.run("tree-sitter", ["generate"],
            output: generate_output,
            error: generate_error
          )

          return false unless generate_status.success?

          # Build grammar
          build_output = IO::Memory.new
          build_error = IO::Memory.new
          build_status = Process.run("tree-sitter", ["build"],
            output: build_output,
            error: build_error
          )

          return false unless build_status.success?

          # Copy to cache
          ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
          source_lib = "#{language}.#{ext}"
          lib_name = "libtree-sitter-#{language}.#{ext}"

          # Rename if needed
          if File.exists?(source_lib) && !File.exists?(lib_name)
            File.rename(source_lib, lib_name)
          end

          # Copy to cache
          if cache_dir = @@cache_dir
            cache_lib_dir = File.join(cache_dir, language)
            Dir.mkdir_p(cache_lib_dir)

            dest_lib = File.join(cache_lib_dir, lib_name)
            if File.exists?(lib_name)
              FileUtils.cp(lib_name, dest_lib)
              return true
            end
          end

          false
        end
      rescue
        false
      end

      # Copy grammar from node_modules
      private def copy_grammar_from_node_modules(language : String, node_modules_path : String, package_name : String) : Bool
        # Look for the grammar file in various locations
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"

        possible_paths = [
          File.join(node_modules_path, package_name, lib_name),
          File.join(node_modules_path, package_name, "build", "Release", lib_name),
          File.join(node_modules_path, package_name, language + ".#{ext}"),
        ]

        source_path = possible_paths.find { |path| File.exists?(path) }
        return false unless source_path

        # Copy to cache
        if cache_dir = @@cache_dir
          cache_lib_dir = File.join(cache_dir, language)
          Dir.mkdir_p(cache_lib_dir)

          dest_lib = File.join(cache_lib_dir, lib_name)
          FileUtils.cp(source_path, dest_lib)
          return true
        end

        false
      end

      # Metadata-related methods

      # Auto-create metadata for existing vendor grammars
      private def self.auto_create_vendor_metadata
        vendor_grammars_dir = File.expand_path("../../vendor/grammars", __DIR__)
        return unless Dir.exists?(vendor_grammars_dir)

        created = GrammarMetadataStore.auto_create_for_existing(vendor_grammars_dir)
        if created && ENV["CHIASMUS_DEBUG"]?
          puts "[GrammarManager] Auto-created metadata for existing vendor grammars"
        end
      end

      # Get metadata for a grammar
      def get_grammar_metadata(language : String) : GrammarMetadata?
        # Check cache directory first
        if cache_dir = @@cache_dir
          language_dir = File.join(cache_dir, language)
          if Dir.exists?(language_dir)
            metadata = GrammarMetadataStore.load(language_dir)
            return metadata if metadata

            # Auto-create metadata if grammar exists but no metadata
            if grammar_directory?(language_dir)
              metadata = auto_create_metadata_for_cache(language, language_dir)
              return metadata if metadata
            end
          end
        end

        # Check vendor directory
        vendor_grammars_dir = File.expand_path("../../vendor/grammars", __DIR__)
        grammar_dir = find_grammar_dir_in_vendor(language, vendor_grammars_dir)
        if grammar_dir && Dir.exists?(grammar_dir)
          return GrammarMetadataStore.load(grammar_dir)
        end

        nil
      end

      # Check if a grammar has updates available (async)
      def update_check_async(language : String) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            metadata = get_grammar_metadata(language)
            unless metadata
              channel.send(Utils::BoolResult.failure(
                "No metadata found for grammar",
                {"language" => language}
              ))
              next
            end

            case metadata.type
            when "git"
              result = check_git_updates_async(metadata)
              channel.send(result)
            when "npm"
              result = check_npm_updates_async(metadata)
              channel.send(result)
            when "local"
              # Local grammars don't have updates
              channel.send(Utils::BoolResult.new(value: false))
            else
              channel.send(Utils::BoolResult.failure(
                "Unknown grammar type",
                {"language" => language, "type" => metadata.type}
              ))
            end
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error checking for updates: #{ex.message}",
              {"language" => language, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Install grammar from local directory (async)
      def install_from_local_async(local_path : String, language : String? = nil) : Channel(Utils::BoolResult)
        channel = Channel(Utils::BoolResult).new

        spawn do
          begin
            unless Dir.exists?(local_path)
              channel.send(Utils::BoolResult.failure(
                "Local directory does not exist",
                {"path" => local_path}
              ))
              next
            end

            # Check if it looks like a tree-sitter grammar
            grammar_json = File.join(local_path, "grammar.json")
            src_dir = File.join(local_path, "src")

            unless File.exists?(grammar_json) || Dir.exists?(src_dir)
              channel.send(Utils::BoolResult.failure(
                "Directory does not appear to be a tree-sitter grammar",
                {"path" => local_path}
              ))
              next
            end

            # Infer language if not provided
            inferred_language = language
            unless inferred_language
              # Try to infer from directory name
              dir_name = File.basename(local_path)
              inferred_language = GrammarMetadataStore.infer_language_from_package(dir_name)

              # Try to infer from grammar.json
              unless inferred_language && File.exists?(grammar_json)
                begin
                  grammar_data = JSON.parse(File.read(grammar_json))
                  if name = grammar_data["name"]?.try(&.as_s?)
                    inferred_language = GrammarMetadataStore.infer_language_from_package(name)
                  end
                rescue
                  # Ignore errors
                end
              end

              unless inferred_language
                channel.send(Utils::BoolResult.failure(
                  "Could not infer language from local grammar. Please specify with --language option.",
                  {"path" => local_path}
                ))
                next
              end
            end

            # Build the grammar
            build_success = build_grammar_async(local_path, inferred_language)
            unless build_success
              channel.send(Utils::BoolResult.failure(
                "Failed to build local grammar",
                {"path" => local_path, "language" => inferred_language}
              ))
              next
            end

            # Copy to cache
            if cache_dir = @@cache_dir
              ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
              lib_name = "libtree-sitter-#{inferred_language}.#{ext}"
              source_lib = File.join(local_path, lib_name)

              unless File.exists?(source_lib)
                # Try alternative name
                source_lib = File.join(local_path, "#{inferred_language}.#{ext}")
              end

              if File.exists?(source_lib)
                cache_lib_dir = File.join(cache_dir, inferred_language)
                Dir.mkdir_p(cache_lib_dir)
                dest_lib = File.join(cache_lib_dir, lib_name)
                FileUtils.cp(source_lib, dest_lib)

                # Create metadata
                metadata = GrammarMetadata.new(
                  url: local_path,
                  type: "local",
                  package_name: File.basename(local_path),
                  language: inferred_language,
                  installed_at: Time.utc,
                  last_updated: Time.utc
                )

                GrammarMetadataStore.save(cache_lib_dir, metadata)

                channel.send(Utils::BoolResult.success)
              else
                channel.send(Utils::BoolResult.failure(
                  "Built library not found",
                  {"path" => local_path, "language" => inferred_language}
                ))
              end
            else
              channel.send(Utils::BoolResult.failure(
                "Cache directory not initialized",
                {"path" => local_path}
              ))
            end
          rescue ex
            channel.send(Utils::BoolResult.failure(
              "Error installing local grammar: #{ex.message}",
              {"path" => local_path, "exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Private helper methods

      private def find_grammar_dir_in_vendor(language : String, vendor_dir : String) : String?
        # Check for tree-sitter-language directory
        dir_name = "tree-sitter-#{language}"
        dir_path = File.join(vendor_dir, dir_name)
        return dir_path if Dir.exists?(dir_path)

        # Check for language directory
        dir_path = File.join(vendor_dir, language)
        return dir_path if Dir.exists?(dir_path)

        nil
      end

      private def check_git_updates_async(metadata : GrammarMetadata) : Utils::BoolResult
        return Utils::BoolResult.failure("No URL for git grammar", {"language" => metadata.language}) if metadata.url.empty?

        begin
          # Create a temporary directory to clone into
          temp_dir = File.join(Dir.tempdir, "chiasmus-git-check-#{Random.rand(1_000_000)}")
          Dir.mkdir_p(temp_dir)

          begin
            # Clone the repository (shallow, single branch)
            clone_result = Process.run("git", ["clone", "--depth", "1", "--single-branch", metadata.url, temp_dir],
              output: Process::Redirect::Close, error: Process::Redirect::Close)

            unless clone_result.success?
              return Utils::BoolResult.failure("Failed to clone repository", {"language" => metadata.language, "url" => metadata.url})
            end

            # Get the latest commit hash
            commit_output = IO::Memory.new
            commit_result = Process.run("git", ["rev-parse", "HEAD"], chdir: temp_dir, output: commit_output)

            unless commit_result.success?
              return Utils::BoolResult.failure("Failed to get latest commit", {"language" => metadata.language})
            end

            latest_commit = commit_output.to_s.strip

            # Compare with local commit
            current_commit = metadata.commit_hash
            if current_commit && latest_commit != current_commit
              Utils::BoolResult.new(value: true, details: {
                "language"       => metadata.language,
                "current_commit" => current_commit,
                "latest_commit"  => latest_commit,
              })
            else
              Utils::BoolResult.new(value: false, details: {"language" => metadata.language})
            end
          ensure
            # Clean up temp directory
            FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
          end
        rescue ex
          Utils::BoolResult.failure("Error checking git updates: #{ex.message}", {
            "language"  => metadata.language,
            "exception" => ex.class.to_s,
          })
        end
      end

      private def check_npm_updates_async(metadata : GrammarMetadata) : Utils::BoolResult
        return Utils::BoolResult.failure("No package name for npm grammar", {"language" => metadata.language}) if metadata.package_name.empty?

        begin
          # Check npm registry for latest version
          # Use npm view command
          npm_output = IO::Memory.new
          npm_view_result = Process.run("npm", ["view", metadata.package_name, "version"], output: npm_output)

          unless npm_view_result.success?
            # Try with --json flag
            npm_output = IO::Memory.new
            npm_view_result = Process.run("npm", ["view", metadata.package_name, "version", "--json"], output: npm_output)

            unless npm_view_result.success?
              return Utils::BoolResult.failure("Failed to check npm registry", {
                "language" => metadata.language,
                "package"  => metadata.package_name,
              })
            end
          end

          latest_version = npm_output.to_s.strip
          # Remove quotes if JSON response
          latest_version = latest_version.gsub(/^"|"$/, "")

          # Compare with local version
          current_version = metadata.version
          if current_version && latest_version != current_version
            Utils::BoolResult.new(value: true, details: {
              "language"        => metadata.language,
              "current_version" => current_version,
              "latest_version"  => latest_version,
            })
          else
            Utils::BoolResult.new(value: false, details: {"language" => metadata.language})
          end
        rescue ex
          Utils::BoolResult.failure("Error checking npm updates: #{ex.message}", {
            "language"  => metadata.language,
            "exception" => ex.class.to_s,
          })
        end
      end

      # Check if a directory contains a grammar library
      private def grammar_directory?(dir_path : String) : Bool
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}

        # Check for libtree-sitter-*.{so,dylib}
        Dir.children(dir_path).any? do |filename|
          filename.starts_with?("libtree-sitter-") && filename.ends_with?(".#{ext}")
        end
      end

      # Auto-create metadata for a grammar in cache directory
      private def auto_create_metadata_for_cache(language : String, language_dir : String) : GrammarMetadata?
        # Try to infer metadata from directory name and contents
        metadata = GrammarMetadataStore.infer_metadata(language_dir)
        return nil unless metadata

        # Save the metadata
        if GrammarMetadataStore.save(language_dir, metadata)
          metadata
        else
          nil
        end
      end
    end
  end
end
