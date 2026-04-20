require "spec"
require "file_utils"
require "../../../src/chiasmus/graph/grammar_manager"
require "../../../src/chiasmus/graph/grammar_metadata"
require "../../../src/chiasmus/graph/language_registry"

describe Chiasmus::Graph::GrammarManager do
  describe "metadata integration" do
    around_each do |test|
      # Create a temporary cache directory
      temp_cache = File.join(Dir.tempdir, "chiasmus-test-cache-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(temp_cache)

      # Reset GrammarManager state
      Chiasmus::Graph::GrammarManager.test_reset(temp_cache)

      begin
        test.run
      ensure
        FileUtils.rm_rf(temp_cache) if Dir.exists?(temp_cache)
      end
    end

    describe ".init with metadata" do
      pending "auto-creates metadata for existing vendor grammars" do
        # This test would require mocking the vendor directory path
        # which is hard-coded in the GrammarManager
        # We'll test the auto_create_vendor_metadata logic indirectly
        # through integration tests
      end
    end

    describe "#install_with_metadata" do
      pending "stores metadata after successful git installation" do
        # This would require mocking git and tree-sitter CLI
        # For now, we'll test the metadata storage logic separately
      end

      pending "stores metadata after successful npm installation" do
      end

      pending "updates metadata on reinstallation" do
      end
    end

    describe "#get_grammar_metadata" do
      it "returns metadata for installed grammar" do
        # Create a mock grammar in cache with metadata
        cache_dir = Chiasmus::Graph::GrammarManager.instance.cache_dir
        next pending "No cache directory" unless cache_dir

        python_dir = File.join(cache_dir, "python")
        Dir.mkdir_p(python_dir)

        metadata = Chiasmus::Graph::GrammarMetadata.new(
          url: "https://github.com/tree-sitter/tree-sitter-python",
          type: "git",
          commit_hash: "abc123",
          package_name: "tree-sitter-python",
          language: "python",
          installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
          last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
        )

        Chiasmus::Graph::GrammarMetadataStore.save(python_dir, metadata)

        # Test get_grammar_metadata method
        result = Chiasmus::Graph::GrammarManager.instance.get_grammar_metadata("python")
        result.should_not be_nil
        result.not_nil!.package_name.should eq "tree-sitter-python"
        result.not_nil!.language.should eq "python"
        result.not_nil!.type.should eq "git"
      end

      it "returns nil for non-existent grammar" do
        result = Chiasmus::Graph::GrammarManager.instance.get_grammar_metadata("nonexistent")
        result.should be_nil
      end
    end

    describe "#update_check_async" do
      pending "checks for updates for git-based grammars" do
      end

      pending "checks for updates for npm-based grammars" do
      end

      pending "returns false for local grammars" do
      end
    end

    describe "#install_from_local_async" do
      pending "installs grammar from local directory" do
      end

      pending "creates local metadata" do
      end

      pending "fails for invalid local directory" do
      end
    end
  end
end
