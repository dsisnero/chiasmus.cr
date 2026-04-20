require "./grammar_manager"
require "./grammar_metadata"
require "../utils/result"

module Chiasmus
  module Graph
    # Batch operations for managing multiple grammars with dependencies
    module GrammarBatchOperations
      # Default required languages for static binary
      DEFAULT_REQUIRED_LANGUAGES = {
        "javascript" => [] of String,
        "typescript" => ["javascript"],
        "tsx"        => ["javascript"],
        "python"     => [] of String,
        "java"       => [] of String,
        "go"         => [] of String,
        "rust"       => [] of String,
        "scala"      => [] of String,
        "ruby"       => [] of String,
        "crystal"    => [] of String,
      }

      # Package names for each language
      DEFAULT_PACKAGE_MAP = {
        "ruby"       => "tree-sitter-ruby",
        "python"     => "tree-sitter-python",
        "java"       => "tree-sitter-java",
        "go"         => "tree-sitter-go",
        "rust"       => "tree-sitter-rust",
        "scala"      => "tree-sitter-scala",
        "javascript" => "tree-sitter-javascript",
        "typescript" => "tree-sitter-typescript",
        "tsx"        => "tree-sitter-typescript",
        "crystal"    => "tree-sitter-crystal",
      }

      # Install multiple grammars with dependency resolution (async)
      def self.install_multiple_async(
        languages : Array(String),
        dependencies : Hash(String, Array(String)) = DEFAULT_REQUIRED_LANGUAGES,
        package_map : Hash(String, String) = DEFAULT_PACKAGE_MAP,
        force : Bool = false,
      ) : Channel(Utils::BatchResult)
        channel = Channel(Utils::BatchResult).new

        spawn do
          begin
            # Resolve dependencies and create installation order
            installation_order = resolve_dependencies(languages, dependencies)

            results = {} of String => Utils::BoolResult
            installed = Set(String).new

            installation_order.each do |language|
              # Check if already installed (unless force)
              unless force
                available_channel = GrammarManager.instance.grammar_available_async(language)
                available_result = Utils::Timeout.with_timeout_async(10_000, available_channel)

                if available_result && available_result.success? && available_result.value == true
                  results[language] = Utils::BoolResult.success
                  installed.add(language)
                  next
                end
              end

              # Check dependencies
              deps = dependencies[language]? || [] of String
              missing_deps = deps.reject { |dep| installed.includes?(dep) }

              unless missing_deps.empty?
                results[language] = Utils::BoolResult.failure(
                  "Missing dependencies: #{missing_deps.join(", ")}",
                  {"language" => language, "missing_dependencies" => missing_deps.join(", ")}
                )
                next
              end

              # Install using GrammarManager
              install_channel = GrammarManager.instance.ensure_grammar_async(language)
              install_result = Utils::Timeout.with_timeout_async(120_000, install_channel)

              if install_result && install_result.success? && install_result.value == true
                results[language] = Utils::BoolResult.success
                installed.add(language)
              else
                results[language] = install_result || Utils::BoolResult.failure(
                  "Installation failed",
                  {"language" => language}
                )
              end
            end

            channel.send(Utils::BatchResult.success(results))
          rescue ex
            channel.send(Utils::BatchResult.failure(
              "Error in batch installation: #{ex.message}",
              {"exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Resolve dependencies and return installation order (topological sort)
      def self.resolve_dependencies(
        languages : Array(String),
        dependencies : Hash(String, Array(String)),
      ) : Array(String)
        # Build graph
        graph = {} of String => Array(String)
        languages.each do |lang|
          graph[lang] = dependencies[lang]? || [] of String
        end

        # Topological sort (Kahn's algorithm)
        in_degree = {} of String => Int32
        graph.each_key { |node| in_degree[node] = 0 }

        graph.each do |node, deps|
          deps.each do |dep|
            if graph.has_key?(dep)
              in_degree[node] = in_degree[node] + 1
            end
          end
        end

        queue = [] of String
        in_degree.each do |node, degree|
          queue << node if degree == 0
        end

        result = [] of String
        until queue.empty?
          node = queue.shift
          result << node

          # Find nodes that depend on this one
          graph.each do |other_node, deps|
            if deps.includes?(node)
              in_degree[other_node] = in_degree[other_node] - 1
              if in_degree[other_node] == 0
                queue << other_node
              end
            end
          end
        end

        # Check for cycles
        if result.size != languages.size
          # Fallback: return in original order
          languages
        else
          result
        end
      end

      # Install all default grammars (async)
      def self.install_all_defaults_async(force : Bool = false) : Channel(Utils::BatchResult)
        languages = DEFAULT_REQUIRED_LANGUAGES.keys.to_a
        install_multiple_async(languages, DEFAULT_REQUIRED_LANGUAGES, DEFAULT_PACKAGE_MAP, force)
      end

      # Check which default grammars are missing (async)
      def self.check_missing_defaults_async : Channel(Utils::BatchResult)
        channel = Channel(Utils::BatchResult).new

        spawn do
          begin
            results = {} of String => Utils::BoolResult

            DEFAULT_REQUIRED_LANGUAGES.keys.each do |language|
              available_channel = GrammarManager.instance.grammar_available_async(language)
              available_result = Utils::Timeout.with_timeout_async(10_000, available_channel)

              if available_result && available_result.success? && available_result.value == true
                results[language] = Utils::BoolResult.new(value: false) # Not missing
              else
                results[language] = Utils::BoolResult.new(value: true) # Missing
              end
            end

            channel.send(Utils::BatchResult.success(results))
          rescue ex
            channel.send(Utils::BatchResult.failure(
              "Error checking missing grammars: #{ex.message}",
              {"exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end

      # Update all installed grammars (async)
      def self.update_all_async(dry_run : Bool = false) : Channel(Utils::BatchResult)
        channel = Channel(Utils::BatchResult).new

        spawn do
          begin
            # Get cache directory
            cache_dir = GrammarManager.instance.cache_dir
            unless cache_dir && Dir.exists?(cache_dir)
              channel.send(Utils::BatchResult.failure(
                "Cache directory not found",
                {"cache_dir" => cache_dir.to_s}
              ))
              next
            end

            results = {} of String => Utils::BoolResult
            updated = 0

            Dir.children(cache_dir).each do |language|
              language_dir = File.join(cache_dir, language)
              next unless Dir.exists?(language_dir)

              # Check for updates
              update_channel = GrammarManager.instance.update_check_async(language)
              update_result = Utils::Timeout.with_timeout_async(30_000, update_channel)

              if update_result && update_result.success?
                if update_result.value == true
                  results[language] = Utils::BoolResult.new(value: true) # Update available

                  unless dry_run
                    # Reinstall
                    install_channel = GrammarManager.instance.ensure_grammar_async(language)
                    install_result = Utils::Timeout.with_timeout_async(120_000, install_channel)

                    if install_result && install_result.success? && install_result.value == true
                      updated += 1
                    else
                      results[language] = Utils::BoolResult.failure(
                        "Failed to update",
                        {"language" => language}
                      )
                    end
                  end
                else
                  results[language] = Utils::BoolResult.new(value: false) # Up to date
                end
              else
                results[language] = update_result || Utils::BoolResult.failure(
                  "Failed to check updates",
                  {"language" => language}
                )
              end
            end

            batch_result = Utils::BatchResult.new(results: results)
            batch_result.metadata = {"updated_count" => updated.to_s}
            channel.send(batch_result)
          rescue ex
            channel.send(Utils::BatchResult.failure(
              "Error updating grammars: #{ex.message}",
              {"exception" => ex.class.to_s}
            ))
          end
        end

        channel
      end
    end
  end
end
