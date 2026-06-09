require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "TypeScript union member extraction" do
  it "extracts object-type union members from discriminated union" do
    code = <<-TS
      type Result<T> = { kind: "ok"; value: T } | { kind: "err"; error: string };
    TS
    sources = [SourceFile.new(path: "/tmp/t.ts", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Result")
    # Union members are anonymous object types, captured with derived names
    graph.defines.size.should be >= 2
  end

  it "extracts each union branch as a separate definition" do
    code = <<-TS
      type Shape = Circle | Square | Triangle;
    TS
    sources = [SourceFile.new(path: "/tmp/t.ts", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Shape")
    # Should also capture the type references
    names.should contain("Circle")
    names.should contain("Square")
    names.should contain("Triangle")
  end
end

describe "Crystal alias union extraction" do
  it "extracts alias name and union members" do
    code = <<-CR
      alias Result = Int32 | String
    CR
    sources = [SourceFile.new(path: "/tmp/t.cr", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Result")
    names.should contain("Int32")
    names.should contain("String")
  end

  it "extracts simple alias" do
    code = <<-CR
      alias Name = String
    CR
    sources = [SourceFile.new(path: "/tmp/t.cr", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Name")
    names.should contain("String")
  end
end
