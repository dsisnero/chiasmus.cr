require "../../spec_helper"
require "golden"

Golden.init
GOLDEN_DIR = File.expand_path("../../testdata/codeium_parse", __DIR__)

private def run_extractor(lang_name, extractor, test_ext)
  lang = Chiasmus::Discovery::GrammarLoader.load_language(lang_name)
  pending "#{lang_name} grammar not available" unless lang

  test_path = File.expand_path(
    "../../../vendor/codeium-parse/test_files/test.#{test_ext}", __DIR__
  )
  source = File.read(test_path)
  parser = TreeSitter::Parser.new(language: lang)
  tree = parser.parse(nil, source)
  items = extractor.extract(tree.root_node, source, "test.#{test_ext}")
  items.sort_by(&.id).map { |i| "#{i.kind}: #{i.name}" }.join("\n")
end

describe "Codeium-parse golden: go" do
  it "matches golden output" do
    output = run_extractor("go", Chiasmus::Discovery::GoExtractor.new, "go")
    Golden.require_equal("test_go", output, test_data_dir: GOLDEN_DIR)
  end
end

describe "Codeium-parse golden: javascript" do
  it "matches golden output" do
    output = run_extractor("javascript", Chiasmus::Discovery::JavaScriptExtractor.new, "js")
    Golden.require_equal("test_javascript", output, test_data_dir: GOLDEN_DIR)
  end
end

describe "Codeium-parse golden: python" do
  it "matches golden output" do
    output = run_extractor("python", Chiasmus::Discovery::PythonExtractor.new, "py")
    Golden.require_equal("test_python", output, test_data_dir: GOLDEN_DIR)
  end
end

describe "Codeium-parse golden: typescript" do
  it "matches golden output" do
    output = run_extractor("typescript", Chiasmus::Discovery::TypeScriptExtractor.new, "tsx")
    Golden.require_equal("test_typescript", output, test_data_dir: GOLDEN_DIR)
  end
end

describe "Codeium-parse golden: ruby" do
  it "matches golden output" do
    output = run_extractor("ruby", Chiasmus::Discovery::RubyExtractor.new, "rb")
    Golden.require_equal("test_ruby", output, test_data_dir: GOLDEN_DIR)
  end
end

describe "Codeium-parse golden: java" do
  it "matches golden output" do
    output = run_extractor("java", Chiasmus::Discovery::JavaExtractor.new, "java")
    Golden.require_equal("test_java", output, test_data_dir: GOLDEN_DIR)
  end
end
