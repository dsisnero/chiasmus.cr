require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Bash graph walker" do
  it "extracts function definitions" do
    code = <<-BASH
      hello() {
        echo "world"
      }
    BASH
    sources = [SourceFile.new(path: "/tmp/t.sh", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("hello")
  end

  it "extracts keyword-style function definitions" do
    code = <<-BASH
      function greet {
        echo "hi"
      }
    BASH
    sources = [SourceFile.new(path: "/tmp/t.sh", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("greet")
  end

  it "captures command calls" do
    code = <<-BASH
      build() {
        npm install
        npm run build
      }
    BASH
    sources = [SourceFile.new(path: "/tmp/t.sh", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("npm")
  end

  it "captures piped command calls" do
    code = <<-BASH
      process() {
        cat file.txt | grep pattern
      }
    BASH
    sources = [SourceFile.new(path: "/tmp/t.sh", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("cat")
    callees.should contain("grep")
  end

  it "produces file nodes for bash files" do
    code = "#!/bin/bash\necho hello"
    sources = [SourceFile.new(path: "/tmp/t.sh", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("bash")
  end
end
