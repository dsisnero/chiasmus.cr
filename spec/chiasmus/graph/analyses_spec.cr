require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/facts"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/analyses"

private def make_graph(
  defines = [] of Chiasmus::Graph::DefinesFact,
  calls = [] of Chiasmus::Graph::CallsFact,
  imports = [] of Chiasmus::Graph::ImportsFact,
  exports = [] of Chiasmus::Graph::ExportsFact,
  contains = [] of Chiasmus::Graph::ContainsFact,
) : Chiasmus::Graph::CodeGraph
  Chiasmus::Graph::CodeGraph.new(
    defines: defines,
    calls: calls,
    imports: imports,
    exports: exports,
    contains: contains
  )
end

describe Chiasmus::Graph::Analyses do
  it "callers returns correct callers" do
    graph = make_graph(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "b", kind: Chiasmus::Graph::SymbolKind::Function, line: 2),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "c", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "c", callee: "b"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Callers,
        target: "b"
      )
    )

    callers = result.result.as(Array(String))
    callers.should contain("a")
    callers.should contain("c")
  end

  it "callees returns correct callees" do
    graph = make_graph(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "b", kind: Chiasmus::Graph::SymbolKind::Function, line: 2),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "c", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "c"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Callees,
        target: "a"
      )
    )

    callees = result.result.as(Array(String))
    callees.should contain("b")
    callees.should contain("c")
  end

  it "returns reachability for transitive paths" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "b", callee: "c"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Reachability,
        from: "a",
        to: "c"
      )
    )

    result.result.should eq({"reachable" => true})
  end

  it "returns false reachability for unconnected nodes" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "c", callee: "d"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Reachability,
        from: "a",
        to: "d"
      )
    )

    result.result.should eq({"reachable" => false})
  end

  it "finds dead code from exported entry points" do
    graph = make_graph(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "used", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "unused", kind: Chiasmus::Graph::SymbolKind::Function, line: 10),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "main", callee: "used"),
      ],
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "t.ts", name: "main"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::DeadCode)
    )

    dead = result.result.as(Array(String))
    dead.should contain("unused")
    dead.should_not contain("main")
    dead.should_not contain("used")
  end

  it "detects cycles" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "b", callee: "c"),
        Chiasmus::Graph::CallsFact.new(caller: "c", callee: "a"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Cycles)
    )

    cycleNodes = result.result.as(Array(String))
    cycleNodes.should contain("a")
    cycleNodes.should contain("b")
    cycleNodes.should contain("c")
  end

  it "returns a path when one exists" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "b", callee: "c"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Path,
        from: "a",
        to: "c"
      )
    )

    result.result.to_s.should contain("a")
    result.result.to_s.should contain("c")
  end

  it "returns impact via reverse reachability" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "main", callee: "handler"),
        Chiasmus::Graph::CallsFact.new(caller: "handler", callee: "validate"),
        Chiasmus::Graph::CallsFact.new(caller: "validate", callee: "query"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Impact,
        target: "query"
      )
    )

    affected = result.result.as(Array(String))
    affected.should contain("validate")
    affected.should contain("handler")
    affected.should contain("main")
  end

  it "returns facts as a Prolog program" do
    graph = make_graph(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Facts)
    )

    result.result.should be_a(String)
    result.result.as(String).should contain("defines(")
    result.result.as(String).should contain("calls(")
    result.result.as(String).should contain("reaches(")
  end

  it "returns summary counts" do
    graph = make_graph(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "a.ts", name: "foo", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "b.ts", name: "bar", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "b.ts", name: "Svc", kind: Chiasmus::Graph::SymbolKind::Class, line: 5),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "foo", callee: "bar"),
      ],
      imports: [
        Chiasmus::Graph::ImportsFact.new(file: "a.ts", name: "bar", source: "./b"),
      ],
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "a.ts", name: "foo"),
      ]
    )

    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      graph,
      Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Summary)
    )

    result.result.should eq(
      {
        "files"     => 2,
        "functions" => 2,
        "classes"   => 1,
        "callEdges" => 1,
        "imports"   => 1,
        "exports"   => 1,
      }
    )
  end

  it "returns a missing parameter error when required fields are absent" do
    result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
      make_graph,
      Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Callers)
    )

    error_val = result.result.as(Hash(String, String))["error"]
    error_val.should match(/missing/i)
  end
end
