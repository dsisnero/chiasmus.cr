require "../../spec_helper"
require "file_utils"
require "../../../src/chiasmus/discovery/grammar_loader"

describe Chiasmus::Discovery::GrammarLoader do
  it "prefers CHIASMUS_GRAMMAR_DIR over registered grammar directories" do
    source_lib = Chiasmus::Discovery::GrammarLoader.find_grammar_library("python")
    next pending "python grammar library not available" unless source_lib

    tmpdir = File.join(Dir.tempdir, "grammar-loader-override-#{Random::Secure.hex(6)}")
    override_dir = File.join(tmpdir, "override")
    grammar_dir = File.join(override_dir, "tree-sitter-python")
    Dir.mkdir_p(grammar_dir)

    dest_lib = File.join(grammar_dir, File.basename(source_lib))
    FileUtils.cp(source_lib, dest_lib)

    begin
      with_env({"CHIASMUS_GRAMMAR_DIR" => override_dir}) do
        Chiasmus::Discovery::GrammarLoader.find_grammar_library("python").should eq(dest_lib)
      end
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end
end
