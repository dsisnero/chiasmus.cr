require "spec"
require "../../src/chiasmus/language_registry"
require "file_utils"

describe Chiasmus::LanguageRegistry do
  it "keeps the shared language extension mapping and unknown-language fallback" do
    Chiasmus::LanguageRegistry.extensions("c").should eq([".c", ".h"])
    Chiasmus::LanguageRegistry.extensions("cpp").should eq([".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"])
    Chiasmus::LanguageRegistry.extensions("kotlin").should eq([".kt", ".kts"])
    Chiasmus::LanguageRegistry.extensions("typescript").should eq([".ts"])
    Chiasmus::LanguageRegistry.extensions("custom").should eq([".custom"])
  end

  it "includes grammar directories under the scan directory" do
    dir = File.join(Dir.tempdir, "language-registry-#{Random::Secure.hex(8)}")
    grammar_dir = File.join(dir, "vendor", "grammars")
    Dir.mkdir_p(grammar_dir)

    begin
      Chiasmus::LanguageRegistry.grammar_directories(dir).should contain(grammar_dir)
      Chiasmus::LanguageRegistry.grammar_directories(dir).count(grammar_dir).should eq(1)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
