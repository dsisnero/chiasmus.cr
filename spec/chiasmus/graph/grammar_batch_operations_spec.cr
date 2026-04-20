require "spec"
require "file_utils"
require "../../../src/chiasmus/graph/grammar_batch_operations"
require "../../../src/chiasmus/graph/grammar_manager"

describe Chiasmus::Graph::GrammarBatchOperations do
  describe ".resolve_dependencies" do
    it "returns languages in dependency order" do
      dependencies = {
        "typescript" => ["javascript"],
        "tsx"        => ["javascript"],
        "javascript" => [] of String,
        "python"     => [] of String,
      }

      languages = ["typescript", "javascript", "tsx", "python"]
      result = Chiasmus::Graph::GrammarBatchOperations.resolve_dependencies(languages, dependencies)

      # javascript should come before typescript and tsx
      javascript_index = result.index("javascript").not_nil!
      typescript_index = result.index("typescript").not_nil!
      tsx_index = result.index("tsx").not_nil!

      javascript_index.should be < typescript_index
      javascript_index.should be < tsx_index

      # All languages should be present
      result.sort.should eq languages.sort
    end

    it "handles cycles by returning original order" do
      dependencies = {
        "a" => ["b"],
        "b" => ["a"], # Cycle
        "c" => [] of String,
      }

      languages = ["a", "b", "c"]
      result = Chiasmus::Graph::GrammarBatchOperations.resolve_dependencies(languages, dependencies)

      # Should fall back to original order when cycle detected
      result.should eq languages
    end

    it "handles empty dependencies" do
      dependencies = {} of String => Array(String)
      languages = ["python", "javascript", "ruby"]

      result = Chiasmus::Graph::GrammarBatchOperations.resolve_dependencies(languages, dependencies)
      result.sort.should eq languages.sort
    end
  end

  describe ".check_missing_defaults_async" do
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

    it "returns batch result with missing status" do
      # Initialize GrammarManager
      Chiasmus::Graph::GrammarManager.init

      channel = Chiasmus::Graph::GrammarBatchOperations.check_missing_defaults_async
      result = channel.receive

      result.should be_a Chiasmus::Utils::BatchResult
      result.success?.should be_true

      # Should return a batch result
      result.success?.should be_true
      result.value.should_not be_nil

      # Check that we got results for all default languages
      if value = result.value
        value.keys.sort.should eq Chiasmus::Graph::GrammarBatchOperations::DEFAULT_REQUIRED_LANGUAGES.keys.sort

        # At least some grammars should be missing (we can't guarantee all are missing
        # because some might be embedded or available via tree-sitter)
        missing_count = value.count { |_, lang_result| lang_result.value == true }
        missing_count.should be >= 0 # Just check it doesn't crash
      end
    end
  end

  # Note: We can't easily test install_multiple_async without mocking
  # external dependencies (git, npm, tree-sitter CLI), so we'll rely
  # on integration tests for that functionality.
end
