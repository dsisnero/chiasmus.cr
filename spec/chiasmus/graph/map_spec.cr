require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/map"

include Chiasmus::Graph

private def make_graph(defines : Array(NamedTuple(name: String, file: String, kind: String, line: Int32)), files : Array(FileNode) = [] of FileNode) : CodeGraph
  CodeGraph.new(
    defines: defines.map { |d|
      DefinesFact.new(
        file: d[:file], name: d[:name],
        kind: case d[:kind]
        when "function" then SymbolKind::Function
        when "method"   then SymbolKind::Method
        when "class"    then SymbolKind::Class
        else                 SymbolKind::Type
        end,
        line: d[:line],
      )
    },
    files: files.empty? ? nil : files,
  )
end

describe CodebaseMap do
  describe ".build_overview" do
    it "returns empty overview for empty graph" do
      map = CodebaseMap.build_overview(CodeGraph.new)
      map.kind.should eq "overview"
      map.summary.files.should eq 0
      map.root.name.should eq ""
    end

    it "groups files into directory tree" do
      graph = make_graph(
        [{name: "foo", file: "src/lib/util.ts", kind: "function", line: 1}],
        [FileNode.new(path: "src/lib/util.ts", language: "typescript")],
      )
      map = CodebaseMap.build_overview(graph)
      map.summary.files.should eq 1
      map.summary.languages.should contain "typescript"
    end
  end

  describe ".build_file_detail" do
    it "returns nil for unknown file" do
      result = CodebaseMap.build_file_detail(CodeGraph.new, "missing.ts")
      result.should be_nil
    end

    it "returns file detail with symbols" do
      graph = make_graph(
        [
          {name: "foo", file: "src/lib.ts", kind: "function", line: 1},
          {name: "bar", file: "src/lib.ts", kind: "function", line: 5},
        ],
        [FileNode.new(path: "src/lib.ts", language: "typescript")],
      )
      detail = CodebaseMap.build_file_detail(graph, "src/lib.ts")
      detail.should_not be_nil
      d = detail.not_nil!
      d.path.should eq "src/lib.ts"
      d.symbols.size.should eq 2
    end
  end

  describe ".build_symbol_detail" do
    it "returns nil for unknown symbol" do
      result = CodebaseMap.build_symbol_detail(CodeGraph.new, "nope")
      result.should be_nil
    end

    it "returns symbol detail with callers and callees" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "helper", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "main", callee: "helper"),
        ],
      )
      detail = CodebaseMap.build_symbol_detail(graph, "main")
      detail.should_not be_nil
      d = detail.not_nil!
      d.name.should eq "main"
      d.callees.should contain "helper"
    end
  end

  describe ".render_map" do
    it "returns JSON string for json format" do
      map = CodebaseMap.build_overview(CodeGraph.new)
      json = CodebaseMap.render_map(map, "json")
      json.should contain "\"kind\""
    end
  end

  describe ".glob_match" do
    it "matches exact paths" do
      CodebaseMap.glob_match("src/index.ts", "src/index.ts").should be_true
      CodebaseMap.glob_match("src/index.ts", "src/other.ts").should be_false
    end

    it "matches ** wildcard" do
      CodebaseMap.glob_match("src/lib/util.ts", "**").should be_true
      CodebaseMap.glob_match("src/lib/util.ts", "**/*.ts").should be_true
    end
  end
end
