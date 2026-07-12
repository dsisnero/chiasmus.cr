require "spec"
require "file_utils"
require "tree-sitter-manager"

describe TreeSitterManager::GrammarManager do
  describe "metadata integration" do
    around_each do |test|
      temp_cache = File.join(Dir.tempdir, "chiasmus-test-cache-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(temp_cache)
      TreeSitterManager::GrammarManager.test_reset(temp_cache)

      begin
        test.run
      ensure
        FileUtils.rm_rf(temp_cache) if Dir.exists?(temp_cache)
      end
    end

    describe "#get_grammar_metadata" do
      it "returns metadata for installed grammar" do
        cache_dir = TreeSitterManager::GrammarManager.instance.cache_dir
        cache_dir.should_not be_nil
        cdir = cache_dir || raise "Expected cache_dir"

        python_dir = File.join(cdir, "python")
        Dir.mkdir_p(python_dir)

        metadata = TreeSitterManager::GrammarMetadata.new(
          url: "https://github.com/tree-sitter/tree-sitter-python",
          type: "git",
          commit_hash: "abc123",
          package_name: "tree-sitter-python",
          language: "python",
          installed_at: Time.utc(2025, 4, 19, 12, 0, 0),
          last_updated: Time.utc(2025, 4, 19, 12, 0, 0)
        )

        TreeSitterManager::GrammarMetadataStore.save(python_dir, metadata)

        result = TreeSitterManager::GrammarManager.instance.get_grammar_metadata("python")
        result.should_not be_nil
        res = result || raise "Expected result"
        res.package_name.should eq "tree-sitter-python"
        res.language.should eq "python"
        res.type.should eq "git"
      end

      it "returns nil for non-existent grammar" do
        result = TreeSitterManager::GrammarManager.instance.get_grammar_metadata("nonexistent")
        result.should be_nil
      end
    end

    describe "#install_from_local_async" do
      it "installs grammar from local directory and creates local metadata" do
        local_root_dir = File.join(Dir.tempdir, "local-grammar-root-#{Random.rand(1_000_000)}")
        local_grammar_dir = File.join(local_root_dir, "tree-sitter-fake")
        temp_bin_dir = File.join(Dir.tempdir, "fake-tree-sitter-bin-#{Random.rand(1_000_000)}")
        original_path = ENV["PATH"]?
        ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}

        Dir.mkdir_p(local_root_dir)
        Dir.mkdir_p(local_grammar_dir)
        Dir.mkdir_p(File.join(local_grammar_dir, "src"))
        Dir.mkdir_p(temp_bin_dir)
        File.write(File.join(local_grammar_dir, "grammar.json"), %({"name":"tree-sitter-fake"}))

        tree_sitter_path = File.join(temp_bin_dir, "tree-sitter")
        File.write(tree_sitter_path, <<-SCRIPT)
#!/bin/sh
case "$1" in
  generate)
    exit 0
    ;;
  build)
    touch "fake.#{ext}"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SCRIPT
        File.chmod(tree_sitter_path, 0o755)
        ENV["PATH"] = "#{temp_bin_dir}:#{original_path}"

        begin
          channel = TreeSitterManager::GrammarManager.instance.install_from_local_async(local_grammar_dir)
          result = channel.receive

          result.success?.should be_true
          result.value.should be_true

          cache_dir = TreeSitterManager::GrammarManager.instance.cache_dir
          cache_dir.should_not be_nil
          cdir = cache_dir || raise "Expected cache_dir"

          fake_dir = File.join(cdir, "fake")
          File.exists?(File.join(fake_dir, "libtree-sitter-fake.#{ext}")).should be_true

          metadata = TreeSitterManager::GrammarMetadataStore.load(fake_dir)
          metadata.should_not be_nil
          md = metadata || raise "Expected metadata"
          md.type.should eq "local"
          md.language.should eq "fake"
          md.url.should eq local_grammar_dir
        ensure
          if original_path
            ENV["PATH"] = original_path
          else
            ENV.delete("PATH")
          end
          FileUtils.rm_rf(local_root_dir)
          FileUtils.rm_rf(temp_bin_dir)
        end
      end

      it "fails for invalid local directory" do
        nonexistent = File.join(Dir.tempdir, "missing-grammar-#{Random.rand(1_000_000)}")

        channel = TreeSitterManager::GrammarManager.instance.install_from_local_async(nonexistent)
        result = channel.receive

        result.failure?.should be_true
        result.error.should_not be_nil
        err = result.error || raise "Expected error"
        err.should contain("Local directory does not exist")
      end
    end
  end
end
