require "../../spec_helper"
require "golden"

Golden.init
GOLDEN_DIR        = File.expand_path("../../testdata/codeium_parse", __DIR__)
CRYSTAL_TEST_PATH = File.expand_path("../../testdata/codeium_parse/crystal_input.txt", __DIR__)

private def extract_for(grammar_lang, test_ext)
  lang = TreeSitterManager::GrammarLoader.load_language(grammar_lang)
  return nil unless lang

  test_path =
    if test_ext == "cr"
      CRYSTAL_TEST_PATH
    else
      File.expand_path(
        "../../../vendor/codeium-parse/test_files/test.#{test_ext}", __DIR__
      )
    end
  source = File.read(test_path)
  parser = TreeSitter::Parser.new(language: lang)
  tree = parser.parse(nil, source)
  {tree, source, test_ext}
end

private def items_output(extractor, tree, source, test_ext)
  items = extractor.extract(tree.root_node, source, "test.#{test_ext}")
  items.sort_by(&.id).map { |i| "#{i.kind}: #{i.name}" }.join("\n")
end

macro golden_spec(lang_key, grammar_lang, test_ext, extractor_class)
  describe "Codeium-parse golden: {{lang_key.id}}" do
    if TreeSitterManager::GrammarLoader.tree_sitter_available?({{grammar_lang}})
      it "matches golden output" do
        result = extract_for({{grammar_lang}}, {{test_ext}})
        result.should_not be_nil
        tree = result.not_nil![0]
        source = result.not_nil![1]
        ext = result.not_nil![2]
        output = items_output({{extractor_class}}.new, tree, source, ext)
        Golden.require_equal("test_{{lang_key.id}}", output, test_data_dir: GOLDEN_DIR)
      end
    else
      pending "matches golden output ({{grammar_lang.id}} grammar not available)"
    end
  end
end

golden_spec(go, "go", "go", Chiasmus::Discovery::GoExtractor)
golden_spec(javascript, "javascript", "js", Chiasmus::Discovery::JavaScriptExtractor)
golden_spec(python, "python", "py", Chiasmus::Discovery::PythonExtractor)
golden_spec(typescript, "typescript", "tsx", Chiasmus::Discovery::TypeScriptExtractor)
golden_spec(ruby, "ruby", "rb", Chiasmus::Discovery::RubyExtractor)
golden_spec(java, "java", "java", Chiasmus::Discovery::JavaExtractor)

golden_spec(bash, "bash", "sh", Chiasmus::Discovery::BashExtractor)
golden_spec(c, "c", "c", Chiasmus::Discovery::CExtractor)
golden_spec(cpp, "cpp", "cpp", Chiasmus::Discovery::CppExtractor)
golden_spec(csharp, "csharp", "cs", Chiasmus::Discovery::CSharpExtractor)
golden_spec(dart, "dart", "dart", Chiasmus::Discovery::DartExtractor)
golden_spec(kotlin, "kotlin", "kt", Chiasmus::Discovery::KotlinExtractor)
golden_spec(perl, "perl", "pl", Chiasmus::Discovery::PerlExtractor)
golden_spec(php, "php", "php", Chiasmus::Discovery::PhpExtractor)
golden_spec(protobuf, "proto", "proto", Chiasmus::Discovery::ProtobufExtractor)
golden_spec(crystal, "crystal", "cr", Chiasmus::Discovery::CrystalExtractor)
