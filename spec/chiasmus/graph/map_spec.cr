require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/map"

include Chiasmus::Graph

private def make_graph(defines : Array(NamedTuple(name: String, file: String, kind: String, line: Int32, signature: String?)), files : Array(FileNode) = [] of FileNode, exports : Array(NamedTuple(file: String, name: String)) = [] of NamedTuple(file: String, name: String), imports : Array(NamedTuple(file: String, name: String, source: String)) = [] of NamedTuple(file: String, name: String, source: String)) : CodeGraph
  defs = defines.map { |defn|
    DefinesFact.new(
      file: defn[:file], name: defn[:name],
      kind: case defn[:kind]
      when "function" then SymbolKind::Function
      when "method"   then SymbolKind::Method
      when "class"    then SymbolKind::Class
      else                 SymbolKind::Type
      end,
      line: defn[:line],
      signature: defn[:signature]?,
    )
  }
  exps = exports.map { |e| ExportsFact.new(file: e[:file], name: e[:name]) }
  imps = imports.map { |i| ImportsFact.new(file: i[:file], name: i[:name], source: i[:source]) }
  CodeGraph.new(
    defines: defs,
    exports: exps,
    imports: imps,
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
        [{name: "foo", file: "src/lib/util.ts", kind: "function", line: 1, signature: nil}],
        [FileNode.new(path: "src/lib/util.ts", language: "typescript")],
      )
      map = CodebaseMap.build_overview(graph)
      map.summary.files.should eq 1
      map.summary.languages.should contain "typescript"
    end

    it "returns summary counts with exports" do
      graph = make_graph(
        [
          {name: "foo", file: "src/a.ts", kind: "function", line: 1, signature: nil},
          {name: "bar", file: "src/b.ts", kind: "function", line: 1, signature: nil},
        ],
        [
          FileNode.new(path: "src/a.ts", language: "typescript"),
          FileNode.new(path: "src/b.ts", language: "typescript"),
        ],
        exports: [
          {file: "src/a.ts", name: "foo"},
          {file: "src/b.ts", name: "bar"},
        ],
      )
      map = CodebaseMap.build_overview(graph)
      map.summary.files.should eq 2
      map.summary.exports.should eq 2
      map.summary.languages.should contain "typescript"
    end

    it "produces file entries with export count and token estimate" do
      graph = make_graph(
        [
          {name: "x", file: "a.ts", kind: "function", line: 1, signature: nil},
          {name: "y", file: "a.ts", kind: "function", line: 3, signature: nil},
        ],
        [FileNode.new(path: "a.ts", language: "typescript", token_estimate: 42)],
        exports: [
          {file: "a.ts", name: "x"},
          {file: "a.ts", name: "y"},
        ],
      )
      map = CodebaseMap.build_overview(graph)
      file = map.root.files[0]
      file.export_count.should eq 2
      file.tokens.should eq 42
    end

    it "truncates topExports to maxExportsPerFile" do
      defines = (0...12).map { |i|
        {name: "f#{i}", file: "a.ts", kind: "function", line: i + 1, signature: nil}
      }
      exports = (0...12).map { |i|
        {file: "a.ts", name: "f#{i}"}
      }
      graph = make_graph(
        defines,
        [FileNode.new(path: "a.ts", language: "typescript")],
        exports: exports,
      )
      map = CodebaseMap.build_overview(graph, max_exports: 3)
      file = map.root.files[0]
      file.top_exports.size.should eq 3
      file.export_count.should eq 12
    end

    it "renders markdown with summary header" do
      graph = make_graph(
        [{name: "foo", file: "src/a.ts", kind: "function", line: 1, signature: nil}],
        [FileNode.new(path: "src/a.ts", language: "typescript")],
      )
      map = CodebaseMap.build_overview(graph)
      md = CodebaseMap.render_map(map, "markdown")
      md.should contain "# Codebase Overview"
    end

    it "captures fileDoc in overview" do
      graph = make_graph(
        [{name: "greet", file: "a.ts", kind: "function", line: 1, signature: nil}],
        [FileNode.new(path: "a.ts", language: "typescript", file_doc: "Greets the world.")],
      )
      map = CodebaseMap.build_overview(graph)
      file = map.root.files[0]
      file.doc.should eq "Greets the world."
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
          {name: "foo", file: "src/lib.ts", kind: "function", line: 1, signature: nil},
          {name: "bar", file: "src/lib.ts", kind: "function", line: 5, signature: nil},
        ],
        [FileNode.new(path: "src/lib.ts", language: "typescript")],
      )
      detail = CodebaseMap.build_file_detail(graph, "src/lib.ts")
      detail.should_not be_nil
      d = detail || raise "Expected detail"
      d.path.should eq "src/lib.ts"
      d.symbols.size.should eq 2
    end

    it "returns exports with signatures and lines" do
      graph = make_graph(
        [
          {name: "foo", file: "src/a.ts", kind: "function", line: 10, signature: "(x: Int32)"},
        ],
        [FileNode.new(path: "src/a.ts", language: "typescript")],
        exports: [{file: "src/a.ts", name: "foo"}],
      )
      detail = CodebaseMap.build_file_detail(graph, "src/a.ts")
      detail.should_not be_nil
      d = detail || raise "Expected detail"
      d.exports.size.should eq 1
      d.exports[0].name.should eq "foo"
      d.exports[0].signature.should eq "(x: Int32)"
    end

    it "returns imports with sources" do
      graph = make_graph(
        [{name: "helper", file: "src/a.ts", kind: "function", line: 1, signature: nil}],
        [FileNode.new(path: "src/a.ts", language: "typescript")],
        imports: [
          {file: "src/a.ts", name: "x", source: "./b"},
          {file: "src/a.ts", name: "y", source: "./b"},
        ],
      )
      detail = CodebaseMap.build_file_detail(graph, "src/a.ts")
      detail.should_not be_nil
      d = detail || raise "Expected detail"
      d.imports.size.should eq 2
      d.imports.map(&.[:source]).sort!.should eq ["./b", "./b"]
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
      d = detail || raise "Expected detail"
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

    it "renders markdown with file entries" do
      graph = make_graph(
        [{name: "Foo", file: "src/a.ts", kind: "class", line: 1, signature: nil}],
        [FileNode.new(path: "src/a.ts", language: "typescript")],
      )
      map = CodebaseMap.build_overview(graph)
      md = CodebaseMap.render_map(map, "markdown")
      md.should contain "# Codebase Overview"
    end
  end

  describe "line_end in output" do
    it "JSON file detail includes line_end when end_line > 0" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, line: 10, end_line: 25),
          DefinesFact.new(file: "a.ts", name: "bar", kind: SymbolKind::Function, line: 30, end_line: 0),
        ],
        files: [FileNode.new(path: "a.ts", language: "typescript")],
      )
      detail = CodebaseMap.build_file_detail(graph, "a.ts")
      detail.should_not be_nil
      d = detail || raise "Expected detail"

      json = CodebaseMap.render_map(d, "json")
      # foo has end_line > 0 → should appear
      json.should contain("foo")
      json.should contain("line_end")
      # bar has end_line 0 → should not have line_end in JSON
      parsed = JSON.parse(json)
      symbols = parsed["symbols"].as_a
      foo_sym = symbols.find { |s| s["name"] == "foo" }
      foo_sym.try { |fs| fs["line_end"].as_i.should eq(25) }

      bar_sym = symbols.find { |s| s["name"] == "bar" }
      bar_sym.try { |bs| bs.as_h.has_key?("line_end").should be_false }
    end

    it "markdown shows line range when end_line > 0" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, line: 10, end_line: 25),
          DefinesFact.new(file: "a.ts", name: "bar", kind: SymbolKind::Function, line: 30, end_line: 0),
        ],
        files: [FileNode.new(path: "a.ts", language: "typescript")],
      )
      detail = CodebaseMap.build_file_detail(graph, "a.ts")
      detail.should_not be_nil
      d = detail || raise "Expected detail"

      md = CodebaseMap.render_map(d, "markdown")
      md.should contain("line 10-25")
      md.should contain("line 30")
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
