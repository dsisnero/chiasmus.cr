require "spec"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/facts"
require "../../../src/chiasmus/solvers/prolog_solver"

private def extract_clojure_graph(content : String, path = "core.clj") : Chiasmus::Graph::CodeGraph
  Chiasmus::Graph::Extractor.extract_graph([
    Chiasmus::Graph::SourceFile.new(path: path, content: content),
  ])
end

describe "Clojure graph extraction" do
  it "extracts defn function definitions" do
    graph = extract_clojure_graph <<-CLJ
      (defn handle-request [req]
        (process req))

      (defn validate [data]
        (check data))
      CLJ

    names = graph.defines.map(&.name)
    names.should contain("handle-request")
    names.should contain("validate")
    graph.defines.all? { |fact| fact.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
  end

  it "extracts defn- as private and not exported" do
    graph = extract_clojure_graph <<-CLJ
      (defn public-fn [x] x)
      (defn- private-fn [x] x)
      CLJ

    export_names = graph.exports.map(&.name)
    export_names.should contain("public-fn")
    export_names.should_not contain("private-fn")
  end

  it "extracts call relationships" do
    graph = extract_clojure_graph <<-CLJ
      (defn a []
        (b)
        (c 1 2))

      (defn b []
        (c))

      (defn c [& args] args)
      CLJ

    graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should eq(["a->b", "a->c", "b->c"])
  end

  it "extracts namespace-qualified calls by local name" do
    graph = extract_clojure_graph <<-CLJ
      (defn handler [req]
        (db/query req)
        (auth/check req))
      CLJ

    callees = graph.calls.select { |call| call.caller == "handler" }.map(&.callee)
    callees.should contain("query")
    callees.should contain("check")
  end

  it "extracts require imports from ns form" do
    graph = extract_clojure_graph <<-CLJ
      (ns myapp.core
        (:require [myapp.db :as db]
                  [myapp.auth :refer [authenticate]]))

      (defn handler [] (authenticate))
      CLJ

    import_names = graph.imports.map(&.name)
    import_names.should contain("myapp.db")
    import_names.should contain("myapp.auth")
  end

  it "extracts multi-file cross-namespace calls" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new(
        path: "core.clj",
        content: <<-CLJ
          (ns myapp.core
            (:require [myapp.db :as db]))

          (defn handler [req]
            (db/query req))
          CLJ
      ),
      Chiasmus::Graph::SourceFile.new(
        path: "db.clj",
        content: <<-CLJ
          (ns myapp.db)

          (defn query [req]
            (execute req))

          (defn execute [req] req)
          CLJ
      ),
    ])

    call_pairs = graph.calls.map { |call| "#{call.caller}->#{call.callee}" }
    call_pairs.should contain("handler->query")
    call_pairs.should contain("query->execute")
  end

  it "deduplicates call edges" do
    graph = extract_clojure_graph <<-CLJ
      (defn a []
        (b)
        (b)
        (b))

      (defn b [] nil)
      CLJ

    graph.calls.count { |call| call.caller == "a" && call.callee == "b" }.should eq(1)
  end

  it "produces valid Prolog facts for reachability" do
    graph = extract_clojure_graph <<-CLJ
      (defn a [] (b))
      (defn b [] (c))
      (defn c [] nil)
      CLJ

    program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(
      Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "reaches(a, c).")
    )
    solver.dispose

    result.status.should eq("success")
    result.as(Chiasmus::Solvers::SuccessResult).answers.should_not be_empty
  end

  it "supports dead code analysis on Clojure graphs" do
    graph = extract_clojure_graph <<-CLJ
      (defn main [] (used))
      (defn used [] nil)
      (defn- unused [] nil)
      CLJ

    program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(
      Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "dead(X).")
    )
    solver.dispose

    result.status.should eq("success")
    dead = result.as(Chiasmus::Solvers::SuccessResult).answers.map { |answer| answer.bindings["X"] }
    dead.should contain("unused")
    dead.should_not contain("main")
    dead.should_not contain("used")
  end
end
