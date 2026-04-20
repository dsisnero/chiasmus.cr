require "option_parser"
require "file_utils"
require "process"
require "path"
require "./graph/language_registry"
require "./graph/grammar_manager"
require "./graph/grammar_metadata"
require "./graph/grammar_batch_operations"
require "./utils/result"
require "./utils/timeout"

module Chiasmus
  # CLI for managing tree-sitter grammars
  class CLI
    @verbose = false
    @force = false
    @dry_run = false
    @all = false
    @local = false
    @language : String? = nil
    @add_language : String? = nil
    @source : String? = nil
    @branch : String? = nil
    @tag : String? = nil
    @cache_dir : String? = nil
    @languages : Array(String) = [] of String

    def initialize
    end

    def run(args : Array(String))
      parse_options(args)
      dispatch_command(@command)
    end

    private def parse_options(args)
      return if args.empty?

      # First argument is the command
      command = args[0]
      remaining_args = args[1..]
      remaining_args = parse_command_args(command, remaining_args)

      # Parse remaining options with OptionParser
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: chiasmus-grammar [command] [options]"

        opts.on("--language LANGUAGE", "Specify language name (for add command)") do |lang|
          @add_language = lang
        end

        opts.on("--branch BRANCH", "Specify git branch (for add command)") do |branch|
          @branch = branch
        end

        opts.on("--tag TAG", "Specify git tag (for add command)") do |tag|
          @tag = tag
        end

        opts.on("--local", "Add from local directory (for add command)") do
          @local = true
        end

        opts.on("--all", "Apply to all grammars") do
          @all = true
        end

        opts.on("--cache-dir DIR", "Specify cache directory") do |dir|
          @cache_dir = dir
        end

        opts.on("--force", "Force recompilation/removal") do
          @force = true
        end

        opts.on("--verbose", "Enable verbose output") do
          @verbose = true
        end

        opts.on("--dry-run", "Show what would be updated without making changes") do
          @dry_run = true
        end

        opts.on("-h", "--help", "Show this help") do
          @command = "help"
        end
      end

      begin
        parser.parse(remaining_args)
      rescue e : OptionParser::InvalidOption
        puts e.message
        puts parser
        exit 1
      end
    end

    private def dispatch_command(command : String?)
      return print_help unless command

      actions = {
        "add"     => -> { add_grammar },
        "remove"  => -> { remove_grammar },
        "compile" => -> { compile_grammar },
        "list"    => -> { list_grammars },
        "status"  => -> { show_status },
        "update"  => -> { update_grammars },
        "clean"   => -> { clean_cache },
        "setup"   => -> { setup_grammars },
        "batch"   => -> { batch_install },
        "help"    => -> { print_help },
      }

      if action = actions[command]?
        action.call
      else
        puts "Unknown command: #{command}"
        print_help
        exit 1
      end
    end

    private def parse_command_args(command : String, remaining_args : Array(String)) : Array(String)
      case command
      when "add"
        @command = "add"
        @source = require_argument(remaining_args, "Error: Source not specified for add command", "Usage: chiasmus-grammar add <url|package|path> [options]")
        remaining_args[1..]
      when "remove"
        @command = "remove"
        @language = require_argument(remaining_args, "Error: Language not specified for remove command", "Usage: chiasmus-grammar remove LANGUAGE [options]")
        remaining_args[1..]
      when "compile"
        @command = "compile"
        @language = require_argument(remaining_args, "Error: Language not specified for compile command", "Usage: chiasmus-grammar compile LANGUAGE [options]")
        remaining_args[1..]
      when "list", "status", "update", "clean", "setup"
        @command = command
        remaining_args
      when "batch"
        @command = "batch"
        language_list = require_argument(remaining_args, "Error: Languages not specified for batch command", "Usage: chiasmus-grammar batch LANGUAGE1,LANGUAGE2,... [options]")
        @languages = language_list.split(',').map(&.strip)
        remaining_args[1..]
      when "help", "-h", "--help"
        @command = "help"
        remaining_args
      else
        puts "Unknown command: #{command}"
        print_help
        exit 1
      end
    end

    private def require_argument(arguments : Array(String), error_message : String, usage : String) : String
      unless value = arguments.first?
        puts error_message
        puts usage
        exit 1
      end

      value
    end

    private def compile_grammar
      language = @language
      unless language
        puts "Error: Language not specified"
        puts "Usage: chiasmus-grammar compile LANGUAGE"
        exit 1
      end

      puts "Compiling #{language} grammar..." if @verbose

      # Check if tree-sitter CLI is available
      unless system("which tree-sitter > /dev/null 2>&1")
        puts "Error: tree-sitter CLI not found. Please install it first:"
        puts "  cargo install tree-sitter-cli"
        exit 1
      end

      # Find grammar source directory
      grammar_dir = find_grammar_dir(language)
      unless grammar_dir && Dir.exists?(grammar_dir)
        puts "Error: Grammar source for '#{language}' not found in vendor/grammars/"
        puts "Available grammars:"
        list_available_grammars
        exit 1
      end

      # Compile the grammar
      success = compile_grammar_dir(grammar_dir, language)

      if success
        puts "Successfully compiled #{language} grammar"

        # Copy to cache if cache_dir is specified
        if cache_dir = @cache_dir || default_cache_dir
          copy_to_cache(grammar_dir, language, cache_dir)
        end
      else
        puts "Failed to compile #{language} grammar"
        exit 1
      end
    end

    private def compile_grammar_dir(grammar_dir : String, language : String) : Bool
      Dir.cd(grammar_dir) do
        # Check if already compiled
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"

        if File.exists?(lib_name) && !@force
          puts "Grammar already compiled: #{lib_name}" if @verbose
          return true
        end

        # Try to generate and build
        puts "Generating parser..." if @verbose
        generate_result = Process.run("tree-sitter", ["generate"], output: @verbose ? Process::Redirect::Inherit : Process::Redirect::Pipe, error: @verbose ? Process::Redirect::Inherit : Process::Redirect::Pipe)

        unless generate_result.success?
          puts "Failed to generate parser" if @verbose
          return false
        end

        puts "Building grammar..." if @verbose
        build_result = Process.run("tree-sitter", ["build"], output: @verbose ? Process::Redirect::Inherit : Process::Redirect::Pipe, error: @verbose ? Process::Redirect::Inherit : Process::Redirect::Pipe)

        unless build_result.success?
          puts "Failed to build grammar" if @verbose
          return false
        end

        # Rename if needed (tree-sitter creates language.dylib/so)
        source_lib = "#{language}.#{ext}"
        if File.exists?(source_lib) && !File.exists?(lib_name)
          File.rename(source_lib, lib_name)
        end

        File.exists?(lib_name)
      end
    end

    private def copy_to_cache(grammar_dir : String, language : String, cache_dir : String)
      ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
      lib_name = "libtree-sitter-#{language}.#{ext}"
      source_lib = File.join(grammar_dir, lib_name)

      unless File.exists?(source_lib)
        puts "Warning: Compiled library not found: #{source_lib}" if @verbose
        return
      end

      # Create cache directory structure
      cache_lib_dir = File.join(cache_dir, language)
      Dir.mkdir_p(cache_lib_dir)

      dest_lib = File.join(cache_lib_dir, lib_name)
      FileUtils.cp(source_lib, dest_lib)

      puts "Copied to cache: #{dest_lib}" if @verbose
    end

    private def list_grammars
      puts "Available grammars in vendor/grammars/:"
      list_available_grammars

      return unless cache_dir = @cache_dir || default_cache_dir
      puts "\nCached grammars in #{cache_dir}:"
      list_cached_grammars(cache_dir)
    end

    private def list_available_grammars
      languages = Graph::LanguageRegistry.supported_languages
      if languages.empty?
        puts "  No languages registered in LanguageRegistry"
      else
        languages.each do |language|
          puts "  #{language}"
        end
      end
    end

    private def list_cached_grammars(cache_dir : String)
      if Dir.exists?(cache_dir)
        Dir.children(cache_dir).each do |lang_dir|
          lib_path = find_grammar_lib(cache_dir, lang_dir)
          if lib_path && File.exists?(lib_path)
            puts "  #{lang_dir} (cached)"
          else
            puts "  #{lang_dir} (incomplete)"
          end
        end
      else
        puts "  Cache directory does not exist"
      end
    end

    private def find_grammar_lib(cache_dir : String, language : String) : String?
      ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
      lib_name = "libtree-sitter-#{language}.#{ext}"

      # Check in language directory
      lib_path = File.join(cache_dir, language, lib_name)
      return lib_path if File.exists?(lib_path)

      # Check in tree-sitter-language directory
      lib_path = File.join(cache_dir, "tree-sitter-#{language}", lib_name)
      return lib_path if File.exists?(lib_path)

      nil
    end

    private def clean_cache
      cache_dir = @cache_dir || default_cache_dir

      unless cache_dir && Dir.exists?(cache_dir)
        puts "Cache directory does not exist: #{cache_dir}"
        return
      end

      puts "Cleaning cache directory: #{cache_dir}" if @verbose

      # Remove all .dylib/.so files
      ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
      Dir.glob(File.join(cache_dir, "**", "*.#{ext}")).each do |lib_file|
        File.delete(lib_file)
        puts "Deleted: #{lib_file}" if @verbose
      end

      # Remove empty directories
      Dir.children(cache_dir).each do |dir|
        dir_path = File.join(cache_dir, dir)
        if Dir.exists?(dir_path) && Dir.empty?(dir_path)
          Dir.delete(dir_path)
          puts "Removed empty directory: #{dir_path}" if @verbose
        end
      end

      puts "Cache cleaned"
    end

    private def find_grammar_dir(language : String) : String?
      vendor_grammars_dir = File.expand_path("../../vendor/grammars", __DIR__)

      # Check for tree-sitter-language directory
      dir_name = "tree-sitter-#{language}"
      dir_path = File.join(vendor_grammars_dir, dir_name)
      return dir_path if Dir.exists?(dir_path)

      # Check for language directory (some grammars might not have tree-sitter- prefix)
      dir_path = File.join(vendor_grammars_dir, language)
      return dir_path if Dir.exists?(dir_path)

      nil
    end

    private def default_cache_dir : String?
      # Use XDG cache directory
      xdg_cache = ENV["XDG_CACHE_HOME"]? || File.join(Path.home, ".cache")
      File.join(xdg_cache, "chiasmus", "grammars")
    end

    # New command implementations

    private def add_grammar
      source = require_source_for_add
      language = @add_language
      branch = @branch
      tag = @tag
      local = @local

      log_add_request(source, language, branch, tag, local)

      # Determine source type and language
      inferred_language = infer_add_language(source, language, local)

      # Initialize GrammarManager
      Chiasmus::Graph::GrammarManager.init(@cache_dir)

      install_grammar_from_source(source, inferred_language, local)
    end

    private def remove_grammar
      language = @language
      unless language
        puts "Error: Language not specified"
        puts "Usage: chiasmus-grammar remove LANGUAGE"
        exit 1
      end

      force = @force

      puts "Removing grammar: #{language}" if @verbose
      puts "Force: #{force}" if force && @verbose

      cache_dir = @cache_dir || default_cache_dir
      unless cache_dir && Dir.exists?(cache_dir)
        puts "Error: Cache directory not found"
        exit 1
      end

      language_dir = File.join(cache_dir, language)
      unless Dir.exists?(language_dir)
        puts "Error: Grammar '#{language}' not found in cache"
        exit 1 unless force
        puts "Warning: Grammar not found, but continuing with force flag"
      end

      # Remove grammar files
      if Dir.exists?(language_dir)
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"
        lib_path = File.join(language_dir, lib_name)

        if File.exists?(lib_path)
          File.delete(lib_path)
          puts "Removed: #{lib_path}" if @verbose
        end

        # Remove metadata
        metadata_path = File.join(language_dir, ".chiasmus-metadata.json")
        if File.exists?(metadata_path)
          File.delete(metadata_path)
          puts "Removed metadata: #{metadata_path}" if @verbose
        end

        # Remove directory if empty
        if Dir.empty?(language_dir)
          Dir.delete(language_dir)
          puts "Removed directory: #{language_dir}" if @verbose
        end
      end

      puts "✓ Removed grammar: #{language}"
    end

    private def show_status
      cache_dir = @cache_dir || default_cache_dir
      verbose = @verbose

      puts "Grammar Status" if verbose
      puts "Cache directory: #{cache_dir}" if verbose
      puts

      # Initialize GrammarManager
      Chiasmus::Graph::GrammarManager.init(cache_dir)

      unless cache_dir && Dir.exists?(cache_dir)
        puts "Cache directory not found"
        return
      end

      grammars_found = false

      Dir.children(cache_dir).each do |language|
        language_dir = File.join(cache_dir, language)
        next unless Dir.exists?(language_dir)

        # Check for grammar library
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
        lib_name = "libtree-sitter-#{language}.#{ext}"
        lib_path = File.join(language_dir, lib_name)

        next unless File.exists?(lib_path)

        grammars_found = true

        # Load metadata (will auto-create if missing)
        metadata = Chiasmus::Graph::GrammarManager.instance.get_grammar_metadata(language)

        if metadata
          puts "✓ #{language}"
          puts "  Source: #{metadata.url}" if metadata.url && !metadata.url.empty?
          puts "  Type: #{metadata.type}"
          puts "  Version: #{metadata.version}" if metadata.version
          if commit_hash = metadata.commit_hash
            puts "  Commit: #{commit_hash[0..7]}" if commit_hash.size >= 8 && verbose
          end
          puts "  Installed: #{metadata.installed_at}" if verbose
          puts "  Updated: #{metadata.last_updated}" if verbose
        else
          puts "✓ #{language} (no metadata)"
        end
      end

      unless grammars_found
        puts "No grammars installed"
      end
    end

    private def update_grammars
      puts "Updating grammar sources..." if @verbose
      puts "Dry run: #{@dry_run}" if @dry_run && @verbose

      vendor_grammars_dir = File.expand_path("../../vendor/grammars", __DIR__)
      unless Dir.exists?(vendor_grammars_dir)
        puts "Error: vendor/grammars directory not found"
        exit 1
      end

      cache_dir = @cache_dir || default_cache_dir
      Chiasmus::Graph::GrammarManager.init(cache_dir)

      updated_count = 0
      repaired_count = 0
      failed_count = 0

      grammar_sources(vendor_grammars_dir).each do |grammar_dir|
        updated, repaired, failed = process_grammar_update(grammar_dir, cache_dir)
        updated_count += updated
        repaired_count += repaired
        failed_count += failed
      end

      if @dry_run
        puts "Dry run complete. #{updated_count} grammars would be refreshed, #{repaired_count} metadata files would be repaired, #{failed_count} would fail."
      else
        puts "Update complete. #{updated_count} grammars refreshed, #{repaired_count} metadata files repaired, #{failed_count} failed."
      end
    end

    # Helper methods

    private def install_grammar(language : String) : Bool
      puts "Installing #{language}..." if @verbose

      channel = Chiasmus::Graph::GrammarManager.instance.ensure_grammar_async(language)
      result = wait_for_channel(channel, 120_000)

      if result && result.success? && result.value == true
        puts "✓ Successfully installed #{language}"
        true
      else
        puts "✗ Failed to install #{language}: #{result.error if result}"
        false
      end
    end

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

    private def grammar_sources(vendor_dir : String) : Array(String)
      Dir.children(vendor_dir)
        .map { |entry| File.join(vendor_dir, entry) }
        .select { |path| Dir.exists?(path) && File.basename(path).starts_with?("tree-sitter-") }
        .sort!
    end

    private def metadata_needs_repair?(
      current : Chiasmus::Graph::GrammarMetadata?,
      inferred : Chiasmus::Graph::GrammarMetadata,
    ) : Bool
      return true unless current

      current.type != inferred.type ||
        current.url != inferred.url ||
        current.package_name != inferred.package_name ||
        current.language != inferred.language ||
        current.commit_hash != inferred.commit_hash ||
        current.version != inferred.version
    end

    private def languages_for_grammar_dir(
      grammar_dir : String,
      metadata : Chiasmus::Graph::GrammarMetadata,
    ) : Array(String)
      package_name = metadata.package_name.empty? ? File.basename(grammar_dir) : metadata.package_name
      return ["typescript", "tsx"] if package_name == "tree-sitter-typescript"

      [metadata.language]
    end

    private def compile_dir_for_language(grammar_dir : String, language : String) : String
      case language
      when "typescript", "tsx"
        subdir = File.join(grammar_dir, language)
        Dir.exists?(subdir) ? subdir : grammar_dir
      else
        grammar_dir
      end
    end

    private def save_cache_metadata(
      language : String,
      metadata : Chiasmus::Graph::GrammarMetadata,
      cache_dir : String?,
    ) : Nil
      return unless cache_dir

      language_dir = File.join(cache_dir, language)
      updated_metadata = Chiasmus::Graph::GrammarMetadata.new(
        url: metadata.url,
        type: metadata.type,
        commit_hash: metadata.commit_hash,
        version: metadata.version,
        package_name: metadata.package_name,
        language: language,
        installed_at: metadata.installed_at,
        last_updated: metadata.last_updated
      )

      Chiasmus::Graph::GrammarMetadataStore.save(language_dir, updated_metadata)
    end

    private def reinstall_grammar(language : String) : Bool
      puts "Reinstalling #{language}..." if @verbose

      # Force reinstall by removing existing files first
      cache_dir = @cache_dir || default_cache_dir
      clear_cached_language(language, cache_dir) if cache_dir

      # Now install fresh - this should create metadata
      install_success = install_grammar(language)

      # Ensure metadata is correct based on vendor directory
      repair_cache_metadata(language, cache_dir) if install_success && cache_dir

      install_success
    end

    private def infer_add_language(source : String, language : String?, local : Bool) : String
      return language if language

      inferred_language = if local
                            Chiasmus::Graph::GrammarMetadataStore.infer_language_from_package(File.basename(source))
                          elsif git_source?(source)
                            Chiasmus::Graph::GrammarMetadataStore.infer_language_from_url(source)
                          else
                            Chiasmus::Graph::GrammarMetadataStore.infer_language_from_package(source)
                          end

      return inferred_language if inferred_language

      puts "Error: Could not infer language from source. Please specify with --language option."
      exit 1
    end

    private def require_source_for_add : String
      source = @source
      return source if source

      puts "Error: Source not specified"
      puts "Usage: chiasmus-grammar add <url|package|path> [options]"
      exit 1
    end

    private def log_add_request(source : String, language : String?, branch : String?, tag : String?, local : Bool) : Nil
      return unless @verbose

      puts "Adding grammar from: #{source}"
      puts "Language: #{language}" if language
      puts "Branch: #{branch}" if branch
      puts "Tag: #{tag}" if tag
      puts "Local: #{local}" if local
    end

    private def install_grammar_from_source(source : String, language : String, local : Bool) : Nil
      if local
        install_local_grammar(source, language)
      elsif git_source?(source)
        install_git_grammar(source, language)
      else
        install_package_grammar(source, language)
      end
    end

    private def git_source?(source : String) : Bool
      source.starts_with?("http://") || source.starts_with?("https://") || source.starts_with?("git@")
    end

    private def install_local_grammar(source : String, language : String) : Nil
      puts "Installing local grammar: #{source} as #{language}"
      channel = Chiasmus::Graph::GrammarManager.instance.install_from_local_async(source, language)
      result = wait_for_channel(channel, 120_000)
      return if result && result.success? && result.value == true && puts("✓ Successfully installed #{language} from local directory").nil?

      puts "✗ Failed to install #{language}: #{result.error if result}"
      exit 1
    end

    private def install_git_grammar(source : String, language : String) : Bool
      puts "Git URL installation not yet fully implemented. Using standard package name."
      package_name = extract_package_name_from_url(source)
      unless package_name
        puts "Error: Could not extract package name from URL"
        exit 1
      end

      register_custom_language(language, package_name)
      install_grammar(language)
    end

    private def install_package_grammar(source : String, language : String) : Bool
      register_custom_language(language, source)
      install_grammar(language)
    end

    private def process_grammar_update(grammar_dir : String, cache_dir : String?) : {Int32, Int32, Int32}
      package_name = File.basename(grammar_dir)
      metadata_before = Chiasmus::Graph::GrammarMetadataStore.load(grammar_dir)
      inferred_metadata = Chiasmus::Graph::GrammarMetadataStore.infer_metadata(grammar_dir)

      unless inferred_metadata
        puts "✗ Could not infer metadata for #{package_name}"
        return {0, 0, 1}
      end

      repaired = metadata_needs_repair?(metadata_before, inferred_metadata)
      languages = languages_for_grammar_dir(grammar_dir, inferred_metadata)

      puts "Processing #{package_name} (#{inferred_metadata.type})..." if @verbose
      return dry_run_update(package_name, languages, repaired) if @dry_run

      metadata = Chiasmus::Graph::GrammarMetadataStore.ensure_metadata(grammar_dir, overwrite: true)
      unless metadata
        puts "✗ Failed to write metadata for #{package_name}"
        return {0, 0, 1}
      end

      refreshed_metadata = Chiasmus::Graph::GrammarMetadataStore.ensure_metadata(grammar_dir, overwrite: true) || metadata
      return {0, repaired ? 1 : 0, 1} unless compile_updated_languages(grammar_dir, languages, refreshed_metadata, cache_dir)

      puts "✓ Updated #{package_name}" if @verbose
      {1, repaired ? 1 : 0, 0}
    end

    private def dry_run_update(package_name : String, languages : Array(String), repaired : Bool) : {Int32, Int32, Int32}
      puts "  Would refresh metadata for #{package_name}" if repaired
      puts "  Would compile #{languages.join(", ")}"
      {1, repaired ? 1 : 0, 0}
    end

    private def compile_updated_languages(
      grammar_dir : String,
      languages : Array(String),
      metadata : Chiasmus::Graph::GrammarMetadata,
      cache_dir : String?,
    ) : Bool
      languages.each do |language|
        compile_dir = compile_dir_for_language(grammar_dir, language)
        unless compile_grammar_dir(compile_dir, language)
          puts "✗ Failed to compile #{language}"
          return false
        end

        copy_to_cache(compile_dir, language, cache_dir) if cache_dir
        save_cache_metadata(language, metadata, cache_dir)
      end

      true
    end

    private def clear_cached_language(language : String, cache_dir : String) : Nil
      language_dir = File.join(cache_dir, language)
      return unless Dir.exists?(language_dir)

      Dir.children(language_dir).each do |filename|
        file_path = File.join(language_dir, filename)
        File.delete(file_path) if File.file?(file_path)
      end
    end

    private def repair_cache_metadata(language : String, cache_dir : String) : Nil
      language_dir = File.join(cache_dir, language)
      return unless Dir.exists?(language_dir)

      vendor_grammars_dir = File.expand_path("../../vendor/grammars", __DIR__)
      vendor_grammar_dir = find_grammar_dir_in_vendor(language, vendor_grammars_dir)
      return unless vendor_grammar_dir && Dir.exists?(vendor_grammar_dir)

      metadata = corrected_vendor_metadata(language, vendor_grammar_dir)
      return unless metadata

      if Chiasmus::Graph::GrammarMetadataStore.save(language_dir, metadata)
        puts "  Created correct metadata for #{language} (type: #{metadata.type}, source: #{metadata.url})" if @verbose
      end
    end

    private def corrected_vendor_metadata(language : String, vendor_grammar_dir : String) : Chiasmus::Graph::GrammarMetadata?
      metadata = Chiasmus::Graph::GrammarMetadataStore.infer_metadata(vendor_grammar_dir)
      return unless metadata

      Chiasmus::Graph::GrammarMetadata.new(
        url: metadata.url,
        type: metadata.type,
        commit_hash: metadata.commit_hash,
        version: metadata.version,
        package_name: metadata.package_name,
        language: language,
        installed_at: Time.utc,
        last_updated: Time.utc
      )
    end

    private def register_custom_language(language : String, package_name : String)
      # Check if language is already registered
      if Chiasmus::Graph::LanguageRegistry.package_name(language)
        return # Already registered
      end

      # Create LanguageInfo for custom language
      info = Chiasmus::Graph::LanguageRegistry::LanguageInfo.new(
        name: language,
        package: package_name,
        extensions: [] of String
      )

      # Register the language
      Chiasmus::Graph::LanguageRegistry.register_language(info)
      puts "Registered custom language: #{language} (#{package_name})" if @verbose
    end

    private def extract_package_name_from_url(url : String) : String?
      # Extract repository name from URL
      # https://github.com/user/repo.git -> repo
      # git@github.com:user/repo.git -> repo

      # Remove .git suffix
      url = url.chomp(".git")

      # Extract last part after /
      if url.includes?('/')
        parts = url.split('/')
        return parts.last if parts.last && !parts.last.empty?
      end

      # For git@github.com:user/repo format
      if url.includes?(':')
        parts = url.split(':')
        if parts.size > 1
          repo_part = parts[1]
          if repo_part.includes?('/')
            repo_parts = repo_part.split('/')
            return repo_parts.last if repo_parts.last && !repo_parts.last.empty?
          end
        end
      end

      nil
    end

    private def wait_for_channel(channel : Channel(Chiasmus::Utils::BoolResult), timeout_ms : Int32) : Chiasmus::Utils::BoolResult?
      select
      when result = channel.receive
        result
      when timeout(timeout_ms.milliseconds)
        Chiasmus::Utils::BoolResult.failure("Timeout after #{timeout_ms}ms")
      end
    end

    private def setup_grammars
      puts "Setting up all default grammars..." if @verbose
      puts "Force reinstall: #{@force}" if @force && @verbose

      # Initialize GrammarManager
      Chiasmus::Graph::GrammarManager.init(@cache_dir)

      puts "Installing default grammars with dependency resolution..."
      channel = Chiasmus::Graph::GrammarBatchOperations.install_all_defaults_async(@force)
      result = wait_for_batch_channel(channel, 300_000) # 5 minutes timeout

      if result && result.success?
        successes = result.successes
        failures = result.failures

        unless successes.empty?
          puts "✓ Successfully installed: #{successes.join(", ")}"
        end

        unless failures.empty?
          puts "✗ Failed to install:"
          failures.each do |language, error|
            puts "  - #{language}: #{error}"
          end
        end

        puts "Setup complete. #{successes.size} grammars installed, #{failures.size} failed."
      else
        puts "✗ Setup failed: #{result.error if result}"
        exit 1
      end
    end

    private def batch_install
      languages = @languages
      if languages.empty?
        puts "Error: No languages specified"
        puts "Usage: chiasmus-grammar batch LANGUAGE1,LANGUAGE2,..."
        exit 1
      end

      puts "Installing grammars: #{languages.join(", ")}" if @verbose
      puts "Force reinstall: #{@force}" if @force && @verbose

      # Initialize GrammarManager
      Chiasmus::Graph::GrammarManager.init(@cache_dir)

      channel = Chiasmus::Graph::GrammarBatchOperations.install_multiple_async(languages, force: @force)
      result = wait_for_batch_channel(channel, 300_000) # 5 minutes timeout

      if result && result.success?
        successes = result.successes
        failures = result.failures

        unless successes.empty?
          puts "✓ Successfully installed: #{successes.join(", ")}"
        end

        unless failures.empty?
          puts "✗ Failed to install:"
          failures.each do |language, error|
            puts "  - #{language}: #{error}"
          end
        end

        puts "Batch installation complete. #{successes.size} grammars installed, #{failures.size} failed."
      else
        puts "✗ Batch installation failed: #{result.error if result}"
        exit 1
      end
    end

    private def wait_for_batch_channel(channel : Channel(Chiasmus::Utils::BatchResult), timeout_ms : Int32) : Chiasmus::Utils::BatchResult?
      select
      when result = channel.receive
        result
      when timeout(timeout_ms.milliseconds)
        Chiasmus::Utils::BatchResult.failure("Timeout after #{timeout_ms}ms")
      end
    end

    private def print_help
      puts <<-HELP
        Chiasmus Grammar Manager

        Commands:
          add SOURCE          Add grammar from git URL, npm package, or local path
          remove LANGUAGE     Remove grammar and metadata
          compile LANGUAGE    Compile a specific grammar
          list                List available and cached grammars
          status              Show installed grammars with version info
          update              Check for updates and recompile if changed
          clean               Clean grammar cache
          setup               Install all default grammars with dependencies
          batch LANGUAGES     Install multiple grammars (comma-separated)
          help                Show this help message

        Add command options:
          --language LANGUAGE Specify language name (auto-detected if not specified)
          --branch BRANCH     Specify git branch
          --tag TAG           Specify git tag
          --local             Add from local directory

        General options:
          --all               Apply to all grammars
          --cache-dir DIR     Specify cache directory (default: XDG_CACHE_HOME/chiasmus/grammars)
          --force             Force recompilation/removal
          --verbose           Enable verbose output
          --dry-run           Show what would be updated without making changes
          -h, --help          Show this help message

        Examples:
          # Add grammars from various sources
          chiasmus-grammar add https://github.com/tree-sitter/tree-sitter-python
          chiasmus-grammar add tree-sitter-javascript
          chiasmus-grammar add /path/to/local/grammar --local --language custom

          # Batch operations
          chiasmus-grammar setup --force
          chiasmus-grammar batch python,javascript,typescript

          # Manage grammars
          chiasmus-grammar remove python --force
          chiasmus-grammar compile python
          chiasmus-grammar compile --all

          # Check status and updates
          chiasmus-grammar list
          chiasmus-grammar status --verbose
          chiasmus-grammar update --dry-run
          chiasmus-grammar update --all

          # Maintenance
          chiasmus-grammar clean --verbose
        HELP
    end

    property command : String? = nil
  end
end
