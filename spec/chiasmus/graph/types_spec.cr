require "spec"
require "../../../src/chiasmus/graph/types"

include Chiasmus::Graph

describe DefinesFact do
  it "generates file::name symbol key" do
    fact = DefinesFact.new(
      file: "src/server.ts",
      name: "handleRequest",
      kind: SymbolKind::Function,
      span: Chiasmus::Graph::Span.line_range(10),
    )
    fact.symbol_key.should eq "src/server.ts::handleRequest"
  end

  it "handles dots and special chars in name" do
    fact = DefinesFact.new(
      file: "src/app.ts",
      name: "UserService.fetch",
      kind: SymbolKind::Method,
      span: Chiasmus::Graph::Span.line_range(5),
    )
    fact.symbol_key.should eq "src/app.ts::UserService.fetch"
  end

  it "produces unique keys for same name in different files" do
    a = DefinesFact.new(file: "a.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))
    b = DefinesFact.new(file: "b.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))
    a.symbol_key.should_not eq b.symbol_key
  end
end
