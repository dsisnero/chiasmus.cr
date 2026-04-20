require "spec"
require "file_utils"
require "json"
require "process"
require "../../../src/chiasmus/graph/grammar_metadata"

module Chiasmus
  module Graph
    describe GrammarMetadata do
      describe "struct" do
        it "serializes to JSON" do
          metadata = GrammarMetadata.new(
            url: "https://github.com/tree-sitter/tree-sitter-python",
            type: "git",
            commit_hash: "abc123def456",
            version: nil,
            package_name: "tree-sitter-python",
            language: "python",
            installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
            last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
          )

          json = metadata.to_json
          parsed = GrammarMetadata.from_json(json)

          parsed.url.should eq "https://github.com/tree-sitter/tree-sitter-python"
          parsed.type.should eq "git"
          parsed.commit_hash.should eq "abc123def456"
          parsed.version.should be_nil
          parsed.package_name.should eq "tree-sitter-python"
          parsed.language.should eq "python"
          parsed.installed_at.should eq Time.utc(2025, 4, 19, 12, 0, 0)
          parsed.last_updated.should eq Time.utc(2025, 4, 19, 12, 0, 0)
        end

        it "serializes npm type with version" do
          metadata = GrammarMetadata.new(
            url: "https://registry.npmjs.org/tree-sitter-javascript",
            type: "npm",
            commit_hash: nil,
            version: "1.0.0",
            package_name: "tree-sitter-javascript",
            language: "javascript",
            installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
            last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
          )

          json = metadata.to_json
          parsed = GrammarMetadata.from_json(json)

          parsed.type.should eq "npm"
          parsed.version.should eq "1.0.0"
          parsed.commit_hash.should be_nil
        end

        it "serializes local type" do
          metadata = GrammarMetadata.new(
            url: "/path/to/local/grammar",
            type: "local",
            commit_hash: nil,
            version: nil,
            package_name: "custom-grammar",
            language: "custom",
            installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
            last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
          )

          json = metadata.to_json
          parsed = GrammarMetadata.from_json(json)

          parsed.type.should eq "local"
          parsed.url.should eq "/path/to/local/grammar"
        end
      end

      describe "GrammarMetadataStore" do
        describe ".load" do
          it "returns nil when metadata file doesn't exist" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              result = GrammarMetadataStore.load(temp_dir)
              result.should be_nil
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "loads metadata from file" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              metadata = GrammarMetadata.new(
                url: "https://github.com/tree-sitter/tree-sitter-python",
                type: "git",
                commit_hash: "abc123",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )

              metadata_path = File.join(temp_dir, ".chiasmus-metadata.json")
              File.write(metadata_path, metadata.to_pretty_json)

              result = GrammarMetadataStore.load(temp_dir)
              result.should_not be_nil
              result.not_nil!.url.should eq metadata.url
              result.not_nil!.language.should eq metadata.language
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "returns nil for invalid JSON" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              metadata_path = File.join(temp_dir, ".chiasmus-metadata.json")
              File.write(metadata_path, "invalid json")

              result = GrammarMetadataStore.load(temp_dir)
              result.should be_nil
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end
        end

        describe ".save" do
          it "saves metadata to file" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              metadata = GrammarMetadata.new(
                url: "https://github.com/tree-sitter/tree-sitter-python",
                type: "git",
                commit_hash: "abc123",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )

              success = GrammarMetadataStore.save(temp_dir, metadata)
              success.should be_true

              metadata_path = File.join(temp_dir, ".chiasmus-metadata.json")
              File.exists?(metadata_path).should be_true

              content = File.read(metadata_path)
              parsed = GrammarMetadata.from_json(content)
              parsed.url.should eq metadata.url
              parsed.language.should eq metadata.language
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "creates directory if it doesn't exist" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            subdir = File.join(temp_dir, "nonexistent", "subdir")
            begin
              metadata = GrammarMetadata.new(
                url: "https://github.com/tree-sitter/tree-sitter-python",
                type: "git",
                commit_hash: "abc123",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )

              success = GrammarMetadataStore.save(subdir, metadata)
              success.should be_true

              metadata_path = File.join(subdir, ".chiasmus-metadata.json")
              File.exists?(metadata_path).should be_true
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "returns false on write error" do
            # Create a read-only directory
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            read_only_dir = File.join(temp_dir, "readonly")
            Dir.mkdir(read_only_dir, 0o444) # Read-only permissions

            begin
              metadata = GrammarMetadata.new(
                url: "https://github.com/tree-sitter/tree-sitter-python",
                type: "git",
                commit_hash: "abc123",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )

              success = GrammarMetadataStore.save(read_only_dir, metadata)
              success.should be_false
            ensure
              # Clean up - need to change permissions first
              File.chmod(read_only_dir, 0o755)
              FileUtils.rm_rf(temp_dir)
            end
          end
        end

        describe ".auto_create_for_existing" do
          it "creates metadata for existing grammar directories" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              # Create a mock grammar directory structure
              grammar_dir = File.join(temp_dir, "tree-sitter-python")
              Dir.mkdir(grammar_dir)

              # Create a package.json to simulate npm package
              package_json = {
                "name"    => "tree-sitter-python",
                "version" => "1.0.0",
              }
              File.write(File.join(grammar_dir, "package.json"), package_json.to_json)

              # Create a .git directory to simulate git repo
              Dir.mkdir(File.join(grammar_dir, ".git"))

              result = GrammarMetadataStore.auto_create_for_existing(temp_dir)
              result.should be_true

              metadata_path = File.join(grammar_dir, ".chiasmus-metadata.json")
              File.exists?(metadata_path).should be_true

              content = File.read(metadata_path)
              metadata = GrammarMetadata.from_json(content)

              metadata.package_name.should eq "tree-sitter-python"
              metadata.language.should eq "python"
              metadata.type.should eq "git" # Should detect git over npm
              metadata.version.should eq "1.0.0"
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "handles directories without package.json or .git" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              # Create a directory that looks like a grammar but has no metadata
              grammar_dir = File.join(temp_dir, "tree-sitter-unknown")
              Dir.mkdir(grammar_dir)

              # Create a grammar.js file to indicate it's a grammar
              File.write(File.join(grammar_dir, "grammar.js"), "// grammar")

              result = GrammarMetadataStore.auto_create_for_existing(temp_dir)
              result.should be_true

              metadata_path = File.join(grammar_dir, ".chiasmus-metadata.json")
              File.exists?(metadata_path).should be_true

              content = File.read(metadata_path)
              metadata = GrammarMetadata.from_json(content)

              metadata.package_name.should eq "tree-sitter-unknown"
              metadata.language.should eq "unknown"
              metadata.type.should eq "local"
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "returns false when no grammar directories found" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              result = GrammarMetadataStore.auto_create_for_existing(temp_dir)
              result.should be_false
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "skips directories that already have metadata" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              grammar_dir = File.join(temp_dir, "tree-sitter-python")
              Dir.mkdir(grammar_dir)

              # Create existing metadata
              existing_metadata = GrammarMetadata.new(
                url: "https://github.com/tree-sitter/tree-sitter-python",
                type: "git",
                commit_hash: "existing",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )

              metadata_path = File.join(grammar_dir, ".chiasmus-metadata.json")
              File.write(metadata_path, existing_metadata.to_pretty_json)

              result = GrammarMetadataStore.auto_create_for_existing(temp_dir)
              result.should be_false # Should return false since no new metadata was created

              # Verify metadata wasn't overwritten
              content = File.read(metadata_path)
              metadata = GrammarMetadata.from_json(content)
              metadata.commit_hash.should eq "existing"
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end

          it "refreshes existing metadata when overwrite is enabled" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              grammar_dir = File.join(temp_dir, "tree-sitter-python")
              Dir.mkdir(grammar_dir)

              package_json = {
                "name"    => "tree-sitter-python",
                "version" => "1.2.3",
              }
              File.write(File.join(grammar_dir, "package.json"), package_json.to_json)

              existing_metadata = GrammarMetadata.new(
                url: "/old/path",
                type: "local",
                package_name: "tree-sitter-python",
                language: "python",
                installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
                last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
              )
              GrammarMetadataStore.save(grammar_dir, existing_metadata)

              result = GrammarMetadataStore.auto_create_for_existing(temp_dir, overwrite: true)
              result.should be_true

              refreshed = GrammarMetadataStore.load(grammar_dir)
              refreshed.should_not be_nil
              refreshed.not_nil!.type.should eq "npm"
              refreshed.not_nil!.url.should eq "https://registry.npmjs.org/tree-sitter-python"
              refreshed.not_nil!.version.should eq "1.2.3"
              refreshed.not_nil!.installed_at.should eq existing_metadata.installed_at
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end
        end

        describe ".infer_metadata" do
          it "captures git origin and commit hash for existing git grammars" do
            temp_dir = File.join(Dir.tempdir, "grammar-metadata-spec-#{Random.rand(1_000_000)}")
            Dir.mkdir_p(temp_dir)
            begin
              grammar_dir = File.join(temp_dir, "tree-sitter-python")
              Dir.mkdir(grammar_dir)
              File.write(File.join(grammar_dir, "package.json"), {
                "name"    => "tree-sitter-python",
                "version" => "0.25.0",
              }.to_json)
              File.write(File.join(grammar_dir, "grammar.js"), "module.exports = {};")

              Process.run("git", ["init"], chdir: grammar_dir).success?.should be_true
              Process.run("git", ["remote", "add", "origin", "https://github.com/tree-sitter/tree-sitter-python.git"], chdir: grammar_dir).success?.should be_true

              metadata = GrammarMetadataStore.infer_metadata(grammar_dir)
              metadata.should_not be_nil
              metadata.not_nil!.type.should eq "git"
              metadata.not_nil!.url.should eq "https://github.com/tree-sitter/tree-sitter-python.git"
              metadata.not_nil!.package_name.should eq "tree-sitter-python"
              metadata.not_nil!.language.should eq "python"
              metadata.not_nil!.version.should eq "0.25.0"
            ensure
              FileUtils.rm_rf(temp_dir)
            end
          end
        end

        describe ".infer_language_from_package" do
          it "extracts language from package name" do
            GrammarMetadataStore.infer_language_from_package("tree-sitter-python").should eq "python"
            GrammarMetadataStore.infer_language_from_package("tree-sitter-javascript").should eq "javascript"
            GrammarMetadataStore.infer_language_from_package("@yogthos/tree-sitter-clojure").should eq "clojure"
            GrammarMetadataStore.infer_language_from_package("tree-sitter-c-sharp").should eq "csharp"
            GrammarMetadataStore.infer_language_from_package("tree-sitter-c").should eq "c"
            GrammarMetadataStore.infer_language_from_package("tree-sitter-cpp").should eq "cpp"
          end

          it "returns package name if no language can be inferred" do
            GrammarMetadataStore.infer_language_from_package("custom-grammar").should eq "custom-grammar"
            GrammarMetadataStore.infer_language_from_package("unknown").should eq "unknown"
          end
        end

        describe ".infer_language_from_url" do
          it "extracts language from GitHub URL" do
            GrammarMetadataStore.infer_language_from_url("https://github.com/tree-sitter/tree-sitter-python").should eq "python"
            GrammarMetadataStore.infer_language_from_url("https://github.com/someuser/tree-sitter-ruby").should eq "ruby"
            GrammarMetadataStore.infer_language_from_url("git@github.com:tree-sitter/tree-sitter-go.git").should eq "go"
          end

          it "extracts language from npm URL" do
            GrammarMetadataStore.infer_language_from_url("https://registry.npmjs.org/tree-sitter-javascript").should eq "javascript"
            GrammarMetadataStore.infer_language_from_url("https://registry.npmjs.org/@yogthos/tree-sitter-clojure").should eq "clojure"
          end

          it "returns nil if no language can be inferred" do
            GrammarMetadataStore.infer_language_from_url("https://example.com/grammar").should be_nil
            GrammarMetadataStore.infer_language_from_url("file:///path/to/grammar").should be_nil
          end
        end
      end
    end
  end
end
