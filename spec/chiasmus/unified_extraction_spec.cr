require "spec"
require "../../src/chiasmus/graph/extractor"

class CountingJavaParser
  getter parse_count = 0

  def language_for_file(file_path : String) : String?
    Chiasmus::Graph::Parser.language_for_file(file_path)
  end

  def parse_source(content : String, file_path : String) : TreeSitter::Tree?
    @parse_count += 1
    Chiasmus::Graph::Parser.parse_source(content, file_path)
  end
end

describe Chiasmus::Graph::Extractor do
  it "runs graph and discovery extraction from one Java parse tree" do
    source = <<-JAVA
      class Greeter {
        void greet() {}
      }
      JAVA
    file = Chiasmus::Graph::SourceFile.new("Greeter.java", source)
    parser = CountingJavaParser.new

    result = Chiasmus::Graph::Extractor.extract_with_discovery(file, "java", parser)
    combined = result || raise "expected combined extraction result"

    parser.parse_count.should eq(1)
    combined.graph.defines.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("greet")
  end
end
