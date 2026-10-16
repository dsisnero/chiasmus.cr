require "../../spec_helper"
require "file_utils"
require "tree-sitter-manager"

describe TreeSitterManager::GrammarLoader do
  it "returns a snapshot of registered grammar directories instead of the shared backing array" do
    baseline_dir = File.expand_path("../../../grammars", __DIR__)
    tmpdir = File.join(Dir.tempdir, "grammar-loader-snapshot-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(tmpdir)
    original_directories = [] of String

    begin
      TreeSitterManager::GrammarLoader.register_grammar_directory(baseline_dir)
      original_directories = TreeSitterManager::GrammarLoader.grammar_directories
      TreeSitterManager::GrammarLoader.clear_registered_directories_for_test
      TreeSitterManager::GrammarLoader.register_grammar_directory(tmpdir)

      snapshot = TreeSitterManager::GrammarLoader.grammar_directories
      snapshot.clear

      TreeSitterManager::GrammarLoader.grammar_directories.should eq([tmpdir])
    ensure
      TreeSitterManager::GrammarLoader.clear_registered_directories_for_test
      original_directories.each { |directory| TreeSitterManager::GrammarLoader.register_grammar_directory(directory) }
      FileUtils.rm_rf(tmpdir)
    end

    TreeSitterManager::GrammarLoader.grammar_directories.should eq(original_directories)
  end

  it "prefers CHIASMUS_GRAMMAR_DIR over registered grammar directories" do
    source_lib = TreeSitterManager::GrammarLoader.find_grammar_library("python")
    next pending "python grammar library not available" unless source_lib

    tmpdir = File.join(Dir.tempdir, "grammar-loader-override-#{Random::Secure.hex(6)}")
    override_dir = File.join(tmpdir, "override")
    grammar_dir = File.join(override_dir, "tree-sitter-python")
    Dir.mkdir_p(grammar_dir)

    dest_lib = File.join(grammar_dir, File.basename(source_lib))
    FileUtils.cp(source_lib, dest_lib)

    begin
      with_env({"CHIASMUS_GRAMMAR_DIR" => override_dir}) do
        TreeSitterManager::GrammarLoader.find_grammar_library("python").should eq(dest_lib)
      end
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end
end
