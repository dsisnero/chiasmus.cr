require "spec"
require "../../../src/chiasmus/graph/mermaid"
require "../../../src/chiasmus/solvers/prolog_solver"

describe Chiasmus::Graph::Mermaid do
  describe ".parse" do
    it "parses simple edge A --> B" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B")
      prolog.should contain("edge(a, b).")
    end

    it "parses nodes with labels" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A[User Input] --> B[Database]")
      prolog.should contain("node(a, 'User Input').")
      prolog.should contain("node(b, 'Database').")
      prolog.should contain("edge(a, b).")
    end

    it "parses labeled edges" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A -->|Yes| B\n  A -->|No| C")
      prolog.should contain("edge(a, b).")
      prolog.should contain("edge(a, c).")
      prolog.should contain("edge_label(a, b, 'Yes').")
      prolog.should contain("edge_label(a, c, 'No').")
    end

    it "parses multiple edges" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B\n  B --> C\n  C --> D\n  A --> D")
      prolog.should contain("edge(a, b).")
      prolog.should contain("edge(b, c).")
      prolog.should contain("edge(c, d).")
      prolog.should contain("edge(a, d).")
    end

    it "normalizes ids to lowercase" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  UserInput --> DbQuery")
      prolog.should contain("edge(userinput, dbquery).")
    end

    it "ignores comments and empty lines" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  %% comment\n  A --> B\n\n  B --> C")
      prolog.should contain("edge(a, b).")
      prolog.should contain("edge(b, c).")
      prolog.should_not contain("comment")
    end

    it "includes reachability rules" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B")
      prolog.should contain("reaches(")
      prolog.should contain("member(")
    end

    it "handles flowchart keyword" do
      prolog = Chiasmus::Graph::Mermaid.parse("flowchart LR\n  A --> B")
      prolog.should contain("edge(a, b).")
    end

    it "handles different arrow styles" do
      prolog = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B\n  B --- C\n  C -.-> D\n  D ==> E")
      prolog.should contain("edge(a, b).")
      prolog.should contain("edge(b, c).")
      prolog.should contain("edge(c, d).")
      prolog.should contain("edge(d, e).")
    end

    it "parses state transitions" do
      prolog = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  Active --> Paused : pause\n  Paused --> Active : resume")
      prolog.should contain("transition(active, paused, pause).")
      prolog.should contain("transition(paused, active, resume).")
    end

    it "handles start and end markers" do
      prolog = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  [*] --> Active\n  Active --> [*] : finish")
      prolog.should contain("transition(start_end, active, auto).")
      prolog.should contain("transition(active, start_end, finish).")
    end

    it "handles transitions without events" do
      prolog = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  Idle --> Running")
      prolog.should contain("transition(idle, running, auto).")
    end

    it "includes can_reach rules" do
      prolog = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  A --> B")
      prolog.should contain("can_reach(")
    end
  end

  describe "solver integration" do
    it "produces valid prolog for flowcharts" do
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Graph::Mermaid.parse("graph TD\n  A[Start] --> B[Middle]\n  B --> C[End]"),
        "edge(a, b)."
      )

      result.status.should eq("success")
    end

    it "supports reachability on flowcharts" do
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B\n  B --> C\n  C --> D"),
        "reaches(a, d)."
      )

      result.status.should eq("success")
      result.as(Chiasmus::Solvers::SuccessResult).answers.size.should be > 0
    end

    it "produces valid prolog for state diagrams" do
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  Idle --> Active : start\n  Active --> Done : finish"),
        "can_reach(idle, done)."
      )

      result.status.should eq("success")
      result.as(Chiasmus::Solvers::SuccessResult).answers.size.should be > 0
    end
  end
end
