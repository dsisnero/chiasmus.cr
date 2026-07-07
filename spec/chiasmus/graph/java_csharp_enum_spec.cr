require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

include Chiasmus::Graph

describe "Java enum member extraction" do
  it "captures enum name and members" do
    code = <<-JAVA
      enum Color { RED, GREEN, BLUE }
    JAVA
    sources = [SourceFile.new(path: "/tmp/t.java", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Color")
    names.should contain("RED")
    names.should contain("GREEN")
    names.should contain("BLUE")
  end
end

describe "C# enum member extraction" do
  if TreeSitterManager::GrammarLoader.tree_sitter_available?("csharp")
    it "captures enum name and members" do
      code = <<-CS
        enum Color { Red, Green, Blue }
      CS
      sources = [SourceFile.new(path: "/tmp/t.cs", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Color")
      names.should contain("Red")
      names.should contain("Green")
      names.should contain("Blue")
    end

    it "captures C# enum with explicit values" do
      code = <<-CS
        enum Permissions { Read = 1, Write = 2, Execute = 4 }
      CS
      sources = [SourceFile.new(path: "/tmp/t.cs", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Read")
      names.should contain("Write")
      names.should contain("Execute")
    end
  else
    pending "captures enum name and members (csharp grammar not available)"
    pending "captures C# enum with explicit values (csharp grammar not available)"
  end
end
