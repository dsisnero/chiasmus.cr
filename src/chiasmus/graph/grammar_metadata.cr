require "json"
require "file_utils"
require "process"
require "time"

module Chiasmus
  module Graph
    # Metadata for tracking grammar installations
    struct GrammarMetadata
      include JSON::Serializable

      # Source URL (git repository, npm registry URL, or local path)
      property url : String = ""

      # Source type: "git", "npm", or "local"
      property type : String = "local"

      # Git commit hash (for git type)
      property commit_hash : String? = nil

      # Package version (for npm type)
      property version : String? = nil

      # Package name (e.g., "tree-sitter-python")
      property package_name : String = ""

      # Language identifier (e.g., "python")
      property language : String = ""

      # When the grammar was first installed
      @[JSON::Field(converter: Time::Format.new("%Y-%m-%dT%H:%M:%SZ"))]
      property installed_at : Time = Time.utc

      # When the grammar was last updated
      @[JSON::Field(converter: Time::Format.new("%Y-%m-%dT%H:%M:%SZ"))]
      property last_updated : Time = Time.utc

      def initialize(
        @url : String = "",
        @type : String = "local",
        @commit_hash : String? = nil,
        @version : String? = nil,
        @package_name : String = "",
        @language : String = "",
        @installed_at : Time = Time.utc,
        @last_updated : Time = Time.utc,
      )
      end

      # Update the last_updated timestamp
      def touch
        @last_updated = Time.utc
      end
    end

    # Store for managing grammar metadata files
    module GrammarMetadataStore
      METADATA_FILENAME = ".chiasmus-metadata.json"

      # Load metadata from a grammar directory
      def self.load(grammar_dir : String) : GrammarMetadata?
        metadata_path = File.join(grammar_dir, METADATA_FILENAME)
        return nil unless File.exists?(metadata_path)

        begin
          metadata_data = File.read(metadata_path)
          GrammarMetadata.from_json(metadata_data)
        rescue JSON::ParseException | File::Error
          nil
        end
      end

      # Save metadata to a grammar directory
      def self.save(grammar_dir : String, metadata : GrammarMetadata) : Bool
        metadata_path = File.join(grammar_dir, METADATA_FILENAME)

        begin
          # Create directory if it doesn't exist
          Dir.mkdir_p(grammar_dir) unless Dir.exists?(grammar_dir)

          # Write metadata
          File.write(metadata_path, metadata.to_pretty_json)
          true
        rescue File::Error
          false
        end
      end

      # Infer metadata and save it, optionally preserving install time from existing metadata
      def self.ensure_metadata(grammar_dir : String, overwrite : Bool = false) : GrammarMetadata?
        existing = load(grammar_dir)
        return existing if existing && !overwrite

        metadata = infer_metadata(grammar_dir)
        return nil unless metadata

        if existing
          metadata.installed_at = existing.installed_at
        end

        return nil unless save(grammar_dir, metadata)
        metadata
      end

      # Auto-create metadata for existing grammar directories
      def self.auto_create_for_existing(grammars_root : String, overwrite : Bool = false) : Bool
        return false unless Dir.exists?(grammars_root)

        created = false
        Dir.each_child(grammars_root) do |entry|
          grammar_dir = File.join(grammars_root, entry)
          next unless Dir.exists?(grammar_dir)

          # Skip if already has metadata
          next if !overwrite && File.exists?(File.join(grammar_dir, METADATA_FILENAME))

          if ensure_metadata(grammar_dir, overwrite: overwrite)
            created = true
          end
        end

        created
      end

      # Infer metadata from an existing grammar directory
      def self.infer_metadata(grammar_dir : String) : GrammarMetadata?
        dir_name = File.basename(grammar_dir)

        # Try to detect source type and extract information
        type = "local"
        url = ""
        commit_hash = nil
        version = nil
        package_name = dir_name
        language = infer_language_from_package(dir_name)

        # Check for git repository
        git_dir = File.join(grammar_dir, ".git")
        if File.exists?(git_dir) || Dir.exists?(git_dir)
          type = "git"
          url = git_origin_url(grammar_dir) || ""
          commit_hash = git_commit_hash(grammar_dir)
        end

        # Check for npm package
        package_json_path = File.join(grammar_dir, "package.json")
        if File.exists?(package_json_path)
          begin
            package_data = File.read(package_json_path)
            package_json = JSON.parse(package_data)

            if name = package_json["name"]?.try(&.as_s?)
              package_name = name
              language = infer_language_from_package(name)
            end

            if ver = package_json["version"]?.try(&.as_s?)
              version = ver
            end

            # If we have package.json but no git, it's likely npm
            unless type == "git"
              type = "npm"
              url = "https://registry.npmjs.org/#{package_name}"
            end
          rescue JSON::ParseException | File::Error
            # Continue with defaults
          end
        end

        # If we couldn't determine a better URL, use a generic one
        if url.empty?
          url = grammar_dir
        end

        GrammarMetadata.new(
          url: url,
          type: type,
          commit_hash: commit_hash,
          version: version,
          package_name: package_name,
          language: language,
          installed_at: Time.utc,
          last_updated: Time.utc
        )
      end

      private def self.git_origin_url(grammar_dir : String) : String?
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run(
          "git",
          ["-C", grammar_dir, "remote", "get-url", "origin"],
          output: output,
          error: error
        )

        return nil unless status.success?
        remote = output.to_s.strip
        remote.empty? ? nil : remote
      rescue
        nil
      end

      private def self.git_commit_hash(grammar_dir : String) : String?
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run(
          "git",
          ["-C", grammar_dir, "rev-parse", "HEAD"],
          output: output,
          error: error
        )

        return nil unless status.success?
        commit = output.to_s.strip
        commit.empty? ? nil : commit
      rescue
        nil
      end

      # Extract language identifier from package name
      def self.infer_language_from_package(package_name : String) : String
        # Remove npm scope if present
        name = package_name
        if name.starts_with?("@")
          parts = name.split('/')
          name = parts.size > 1 ? parts[1] : parts[0]
        end

        # Remove "tree-sitter-" prefix
        if name.starts_with?("tree-sitter-")
          language = name["tree-sitter-".size..]

          # Handle special cases
          case language
          when "c-sharp"
            "csharp"
          when "c", "cpp"
            language
          else
            language
          end
        else
          name
        end
      end

      # Extract language identifier from URL
      def self.infer_language_from_url(url : String) : String?
        # GitHub URLs
        if url.includes?("github.com")
          # Match patterns like:
          # - https://github.com/tree-sitter/tree-sitter-python
          # - https://github.com/someuser/tree-sitter-ruby
          # - git@github.com:tree-sitter/tree-sitter-go.git
          match = url.match(/tree-sitter-([a-zA-Z0-9_-]+)(?:\.git)?$/)
          return match[1] if match

          # Also check for repository name that ends with tree-sitter-*
          match = url.match(/\/(tree-sitter-[a-zA-Z0-9_-]+)(?:\.git)?$/)
          if match
            package_name = match[1]
            return infer_language_from_package(package_name)
          end
        end

        # npm registry URLs
        if url.includes?("registry.npmjs.org")
          # Match patterns like:
          # - https://registry.npmjs.org/tree-sitter-javascript
          # - https://registry.npmjs.org/@yogthos/tree-sitter-clojure
          match = url.match(/\/(?:@[^\/]+\/)?(tree-sitter-[a-zA-Z0-9_-]+)$/)
          if match
            package_name = match[1]
            return infer_language_from_package(package_name)
          end
        end

        nil
      end
    end
  end
end
