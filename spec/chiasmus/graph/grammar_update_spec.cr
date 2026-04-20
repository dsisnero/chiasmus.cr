require "spec"
require "file_utils"
require "../../../src/chiasmus/graph/grammar_manager"
require "../../../src/chiasmus/graph/grammar_metadata"

describe Chiasmus::Graph::GrammarManager do
  describe "update checking" do
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

    describe "git update checking via update_check_async" do
      it "handles git grammars without URL" do
        metadata = Chiasmus::Graph::GrammarMetadata.new(
          url: "",
          type: "git",
          commit_hash: "abc123",
          package_name: "tree-sitter-python",
          language: "python",
          installed_at: Time.utc,
          last_updated: Time.utc
        )

        cache_dir = Chiasmus::Graph::GrammarManager.instance.cache_dir
        next pending "No cache directory" unless cache_dir

        language_dir = File.join(cache_dir, "python")
        Dir.mkdir_p(language_dir)
        Chiasmus::Graph::GrammarMetadataStore.save(language_dir, metadata)

        channel = Chiasmus::Graph::GrammarManager.instance.update_check_async("python")
        result = channel.receive

        result.should be_a Chiasmus::Utils::BoolResult
        result.failure?.should be_true
        result.error.should_not be_nil
        result.error.not_nil!.should contain("No URL for git grammar")
      end
    end

    describe "npm update checking via update_check_async" do
      it "handles npm grammars without package name" do
        metadata = Chiasmus::Graph::GrammarMetadata.new(
          url: "https://registry.npmjs.org/tree-sitter-javascript",
          type: "npm",
          version: "1.0.0",
          package_name: "",
          language: "javascript",
          installed_at: Time.utc,
          last_updated: Time.utc
        )

        cache_dir = Chiasmus::Graph::GrammarManager.instance.cache_dir
        next pending "No cache directory" unless cache_dir

        language_dir = File.join(cache_dir, "javascript")
        Dir.mkdir_p(language_dir)
        Chiasmus::Graph::GrammarMetadataStore.save(language_dir, metadata)

        channel = Chiasmus::Graph::GrammarManager.instance.update_check_async("javascript")
        result = channel.receive

        result.should be_a Chiasmus::Utils::BoolResult
        result.failure?.should be_true
        result.error.should_not be_nil
        result.error.not_nil!.should contain("No package name for npm grammar")
      end
    end

    describe "#update_check_async" do
      it "returns false for local grammars" do
        metadata = Chiasmus::Graph::GrammarMetadata.new(
          url: "/path/to/local/grammar",
          type: "local",
          package_name: "custom-grammar",
          language: "custom",
          installed_at: Time.utc,
          last_updated: Time.utc
        )

        # Create a mock grammar in cache with metadata
        cache_dir = Chiasmus::Graph::GrammarManager.instance.cache_dir
        next pending "No cache directory" unless cache_dir

        language_dir = File.join(cache_dir, "custom")
        Dir.mkdir_p(language_dir)
        Chiasmus::Graph::GrammarMetadataStore.save(language_dir, metadata)

        channel = Chiasmus::Graph::GrammarManager.instance.update_check_async("custom")
        result = channel.receive

        result.should be_a Chiasmus::Utils::BoolResult
        result.success?.should be_true
        result.value.should be_false # No updates for local grammars
      end

      it "returns failure for unknown grammar type" do
        metadata = Chiasmus::Graph::GrammarMetadata.new(
          url: "some://weird/url",
          type: "unknown",
          package_name: "weird-grammar",
          language: "weird",
          installed_at: Time.utc,
          last_updated: Time.utc
        )

        cache_dir = Chiasmus::Graph::GrammarManager.instance.cache_dir
        next pending "No cache directory" unless cache_dir

        language_dir = File.join(cache_dir, "weird")
        Dir.mkdir_p(language_dir)
        Chiasmus::Graph::GrammarMetadataStore.save(language_dir, metadata)

        channel = Chiasmus::Graph::GrammarManager.instance.update_check_async("weird")
        result = channel.receive

        result.should be_a Chiasmus::Utils::BoolResult
        result.failure?.should be_true
        result.error.should_not be_nil
        result.error.not_nil!.should contain("Unknown grammar type")
      end
    end
  end
end
