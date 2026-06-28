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

  it "run_analysis_from_graph_async returns a channel before the result is released" do
    graph = make_graph(
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
        Chiasmus::Graph::CallsFact.new(caller: "b", callee: "c"),
      ]
    )
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)

    Chiasmus::Graph::Analyses.set_before_async_result_send_hook_for_test do
      entered.send(true)
      release.receive?
    end

    begin
      result_channel = Chiasmus::Graph::Analyses.run_analysis_from_graph_async(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Reachability,
          from: "a",
          to: "c"
        )
      )

      entered.receive.should be_true

      select
      when result_channel.receive?
        fail("expected async analysis result to remain pending until released")
      else
      end

      release.send(true)
      result = result_channel.receive?
      result.should_not be_nil
      async_result = result || raise "expected async graph result"
      async_result.error.should be_nil
      async_result.value.should_not be_nil
      value = async_result.value || raise "expected async graph value"
      value.result.should eq({"reachable" => true})
      result_channel.receive?.should be_nil
    ensure
      Chiasmus::Graph::Analyses.clear_before_async_result_send_hook_for_test
    end
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

    cycle_nodes = result.result.as(Array(String))
    cycle_nodes.should contain("a")
    cycle_nodes.should contain("b")
    cycle_nodes.should contain("c")
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

  describe "diff and snapshot analysis" do
    it "diff returns error when against name is nil" do
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        make_graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Diff),
        snapshot_cache_dir: "/tmp/cache",
      )
      result.result.as(String).should contain("diff requires a snapshot name")
    end

    it "diff returns error when snapshot_cache_dir is nil" do
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        make_graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Diff, against: "baseline"),
      )
      result.result.as(String).should contain("diff requires a cache directory")
    end

    it "diff returns error when snapshot not found" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-diff-notfound-#{Random::Secure.hex(8)}")
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        make_graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Diff, against: "nonexistent"),
        snapshot_cache_dir: cache_dir,
      )
      result.result.as(String).should contain("not found")
    end

    it "diff returns added/removed nodes when snapshot exists" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-diff-#{Random::Secure.hex(8)}")

      before = Chiasmus::Graph::CodeGraph.new(
        defines: [Chiasmus::Graph::DefinesFact.new(file: "a.go", name: "oldFunc", kind: Chiasmus::Graph::SymbolKind::Function, line: 1)],
      )
      Chiasmus::Graph::GraphCache.save_snapshot("base", before, cache_dir)

      after = make_graph(
        defines: [Chiasmus::Graph::DefinesFact.new(file: "a.go", name: "newFunc", kind: Chiasmus::Graph::SymbolKind::Function, line: 1)],
      )

      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        after,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Diff, against: "base"),
        snapshot_cache_dir: cache_dir,
      )
      json = result.result.as(String)
      json.should contain("added_nodes")
      json.should contain("removed_nodes")
      json.should contain("oldFunc")
      json.should contain("newFunc")

      FileUtils.rm_rf(cache_dir)
    end

    it "rejects save_snapshot == against for diff analysis" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-guard-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(cache_dir)
      go_file = File.join(Dir.tempdir, "guard-test-#{Random::Secure.hex(8)}.go")
      File.write(go_file, "package main\nfunc f() {}")

      result = Chiasmus::Graph::Analyses.run_analysis(
        [go_file],
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Diff, against: "same"),
        cache_dir: cache_dir,
        save_snapshot: "same",
      )

      # The code doesn't let through invalid requests, so check it returns an error
      result.analysis.should eq(Chiasmus::Graph::AnalysisType::Diff)
      result.result.to_s.should contain("cannot name the same snapshot")

      File.delete(go_file)
      FileUtils.rm_rf(cache_dir)
    end

    it "run_analysis_async returns the same result payload as run_analysis" do
      go_file = File.join(Dir.tempdir, "async-analysis-#{Random::Secure.hex(8)}.go")
      File.write(go_file, "package main\nfunc a() { b() }\nfunc b() {}\n")

      request = Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Summary
      )

      begin
        sync = Chiasmus::Graph::Analyses.run_analysis([go_file], request)
        async_channel = Chiasmus::Graph::Analyses.run_analysis_async([go_file], request)
        async = async_channel.receive?

        async.should_not be_nil
        async_result = async || raise "expected analysis async result"
        async_result.error.should be_nil
        async_result.value.should_not be_nil
        value = async_result.value || raise "expected analysis async value"
        value.analysis.should eq(sync.analysis)
        value.result.should eq(sync.result)
        async_channel.receive?.should be_nil
      ensure
        File.delete(go_file) if File.exists?(go_file)
      end
    end

    it "run_analysis_async returns file-read failures through the channel" do
      request = Chiasmus::Graph::AnalysisRequest.new(
        analysis: Chiasmus::Graph::AnalysisType::Summary
      )

      async_channel = Chiasmus::Graph::Analyses.run_analysis_async(
        ["/nonexistent/run-analysis-#{Random::Secure.hex(8)}.go"],
        request
      )
      async = async_channel.receive?

      async.should_not be_nil
      async_result = async || raise "expected async failure result"
      async_result.value.should be_nil
      async_result.error.should_not be_nil
      error = async_result.error || raise "expected async failure error"
      error.should contain("Failed to read")
      async_channel.receive?.should be_nil
    end
  end
end
