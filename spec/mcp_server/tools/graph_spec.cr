require "../../spec_helper"
require "json"

# Build a minimal Go call graph for analysis testing.
private def minimal_go_graph
  Chiasmus::Graph::CodeGraph.new(
    defines: [
      Chiasmus::Graph::DefinesFact.new(file: "main.go", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      Chiasmus::Graph::DefinesFact.new(file: "main.go", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
      Chiasmus::Graph::DefinesFact.new(file: "main.go", name: "unused", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
      Chiasmus::Graph::DefinesFact.new(file: "main.go", name: "Server", kind: Chiasmus::Graph::SymbolKind::Class, line: 3),
    ],
    calls: [
      Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
      Chiasmus::Graph::CallsFact.new(caller: "client", callee: "helper"),
    ],
    imports: [] of Chiasmus::Graph::ImportsFact,
    exports: [
      Chiasmus::Graph::ExportsFact.new(file: "main.go", name: "main"),
    ],
    contains: [] of Chiasmus::Graph::ContainsFact,
  )
end

private def invoke_graph(args : Hash(String, JSON::Any))
  tool = Chiasmus::MCPServer::Tools::GraphTool.new
  tool.invoke(args)
end

describe Chiasmus::MCPServer::Tools::GraphTool do
  describe "tool metadata" do
    it "has correct tool name" do
      Chiasmus::MCPServer::Tools::GraphTool.tool_name.should eq("chiasmus_graph")
    end

    it "provides a tool description" do
      Chiasmus::MCPServer::Tools::GraphTool.tool_description.should_not be_empty
    end

    it "declares input schema with required parameters" do
      schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
      schema.should_not be_nil
    end
  end

  describe "error handling" do
    it "requires files and analysis parameters" do
      result = invoke_graph({"analysis" => JSON::Any.new("summary")})
      result["status"].as_s.should eq("error")
      result["error"].to_s.should contain("files")
    end

    it "rejects unknown analysis type" do
      result = invoke_graph({
        "files"    => JSON.parse(%(["test.go"])),
        "analysis" => JSON::Any.new("nonexistent"),
      })
      result["status"].as_s.should eq("error")
      result["error"].to_s.should contain("Unknown analysis")
    end

    it "handles file not found" do
      result = invoke_graph({
        "files"    => JSON.parse(%(["/nonexistent/path.go"])),
        "analysis" => JSON::Any.new("summary"),
      })
      result["status"].as_s.should eq("error")
    end
  end

  describe "analysis enum validation" do
    it "accepts all 9 valid analysis types" do
      Chiasmus::MCPServer::VALID_ANALYSES.each do |analysis|
        Chiasmus::Graph::AnalysisType.parse?(analysis).should_not be_nil, "expected #{analysis} to be valid"
      end
    end

    it "rejects invalid analysis types at parse level" do
      Chiasmus::Graph::AnalysisType.parse?("invalid").should be_nil
    end
  end
end

describe Chiasmus::Graph::Analyses do
  describe "summary analysis" do
    it "builds summary stats from code graph" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Summary)
      )

      result.analysis.should eq(Chiasmus::Graph::AnalysisType::Summary)
      summary = result.result.as(Hash(String, Int32))
      summary["functions"].should eq(3)
      summary["callEdges"].should eq(2)
      summary["classes"].should eq(1)
      summary["files"].should eq(1)
      summary["imports"].should eq(0)
    end
  end

  describe "callers analysis" do
    it "finds callers of a target function" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Callers,
          target: "helper"
        )
      )

      callers_list = result.result.as(Array(String))
      callers_list.should contain("main")
      callers_list.should contain("client")
    end

    it "returns missing parameter error without target" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Callers)
      )

      err = result.result.as(Hash(String, String))
      err["error"].should eq("Missing required parameters")
    end
  end

  describe "callees analysis" do
    it "finds callees of a source function" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Callees,
          target: "main"
        )
      )

      callees_list = result.result.as(Array(String))
      callees_list.should contain("helper")
    end
  end

  describe "reachability analysis" do
    it "confirms reachable path" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Reachability,
          from: "main", to: "helper"
        )
      )

      reachable = result.result.as(Hash(String, Bool))
      reachable["reachable"].should be_true
    end

    it "confirms unreachable path" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Reachability,
          from: "helper", to: "unused"
        )
      )

      reachable = result.result.as(Hash(String, Bool))
      reachable["reachable"].should be_false
    end
  end

  describe "dead-code analysis" do
    it "finds functions not called and not exported" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::DeadCode,
          entry_points: ["main"]
        )
      )

      dead = result.result.as(Array(String))
      dead.should contain("unused")
    end
  end

  describe "cycles analysis" do
    it "detects no cycles for acyclic graph" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Cycles)
      )

      cycles = result.result.as(Array(String))
      cycles.should be_empty
    end

    it "detects cycles for cyclic graph" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "test.go", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "test.go", name: "b", kind: Chiasmus::Graph::SymbolKind::Function, line: 2),
          Chiasmus::Graph::DefinesFact.new(file: "test.go", name: "c", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
          Chiasmus::Graph::CallsFact.new(caller: "b", callee: "a"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(analysis: Chiasmus::Graph::AnalysisType::Cycles)
      )

      cycles = result.result.as(Array(String))
      cycles.should contain("a")
      cycles.should contain("b")
      cycles.should_not contain("c")
    end
  end

  describe "path analysis" do
    it "finds call path between functions" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Path,
          from: "main", to: "helper"
        )
      )

      path_result = result.result.as(Hash(String, Array(Array(String))))
      path_result["paths"].should_not be_empty
      path_result["paths"][0].should eq(["main", "helper"])
    end

    it "returns empty paths for unreachable target" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Path,
          from: "main", to: "unused"
        )
      )

      path_result = result.result.as(Hash(String, Array(Array(String))))
      path_result["paths"].should be_empty
    end
  end

  describe "impact analysis" do
    it "finds functions affected by a target change" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Impact,
          target: "helper"
        )
      )

      affected = result.result.as(Array(String))
      affected.should contain("main")
      affected.should contain("client")
    end
  end

  describe "facts analysis" do
    it "generates Prolog facts from code graph" do
      graph = minimal_go_graph
      result = Chiasmus::Graph::Analyses.run_analysis_from_graph(
        graph,
        Chiasmus::Graph::AnalysisRequest.new(
          analysis: Chiasmus::Graph::AnalysisType::Facts,
          entry_points: ["main"]
        )
      )

      facts = result.result.as(String)
      facts.should contain("defines")
      facts.should contain("calls")
      facts.should contain("main")
      facts.should contain("helper")
    end
  end
end

describe Chiasmus::MCPServer::Tools::GraphTool do
  describe "MCP integration with real files" do
    it "returns summary for a Go source file via MCP tool invocation" do
      tmpdir = Dir.tempdir
      file_path = File.join(tmpdir, "summary_test.go")
      source = "package main\nfunc main() { helper() }\nfunc helper() {}\n"
      File.write(file_path, source)

      begin
        result = invoke_graph({
          "files"    => JSON.parse([file_path].to_json),
          "analysis" => JSON::Any.new("summary"),
        })

        result["status"].as_s.should eq("success")
        result["analysis"].as_s.should eq("summary")
      ensure
        File.delete(file_path) if File.exists?(file_path)
      end
    end

    it "finds callers of a target function via MCP" do
      tmpdir = Dir.tempdir
      file_path = File.join(tmpdir, "callers_test.go")
      source = "package main\nfunc main() { helper() }\nfunc helper() {}\n"
      File.write(file_path, source)

      begin
        result = invoke_graph({
          "files"    => JSON.parse([file_path].to_json),
          "analysis" => JSON::Any.new("callers"),
          "target"   => JSON::Any.new("helper"),
        })

        result["status"].as_s.should eq("success")
      ensure
        File.delete(file_path) if File.exists?(file_path)
      end
    end

    it "returns error for missing required files parameter" do
      result = invoke_graph({
        "analysis" => JSON::Any.new("summary"),
      })

      result["status"].as_s.should eq("error")
    end

    it "returns error for unknown analysis type via MCP" do
      tmpdir = Dir.tempdir
      file_path = File.join(tmpdir, "error_test.go")
      File.write(file_path, "package main\nfunc main() {}\n")

      begin
        result = invoke_graph({
          "files"    => JSON.parse([file_path].to_json),
          "analysis" => JSON::Any.new("unknown_type"),
        })

        result["status"].as_s.should eq("error")
        result["error"].to_s.should contain("Unknown analysis")
      ensure
        File.delete(file_path) if File.exists?(file_path)
      end
    end

    it "returns facts as raw Prolog via MCP" do
      tmpdir = Dir.tempdir
      file_path = File.join(tmpdir, "facts_test.go")
      source = "package main\nfunc main() { helper() }\nfunc helper() {}\n"
      File.write(file_path, source)

      begin
        result = invoke_graph({
          "files"    => JSON.parse([file_path].to_json),
          "analysis" => JSON::Any.new("facts"),
        })

        result["status"].as_s.should eq("success")
        result["result"].to_s.should contain("defines")
      ensure
        File.delete(file_path) if File.exists?(file_path)
      end
    end
  end
end
