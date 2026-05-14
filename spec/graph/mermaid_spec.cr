require "../spec_helper"

describe Chiasmus::Graph::Mermaid do
  describe ".normalize_id" do
    it "downcases and normalizes IDs" do
      Chiasmus::Graph::Mermaid.normalize_id("ServiceA").should eq("servicea")
    end

    it "handles special characters" do
      Chiasmus::Graph::Mermaid.normalize_id("my-node").should eq("my_node")
    end

    it "handles [*] start/end marker" do
      Chiasmus::Graph::Mermaid.normalize_id("[*]").should eq("start_end")
    end
  end

  describe ".parse" do
    it "parses simple edge A --> B" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B")
      result.should contain("edge(")
      result.should contain("a")
      result.should contain("b")
    end

    it "parses nodes with labels" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  A[Service A] --> B[Service B]")
      result.should contain("node(")
      result.should contain("edge(a, b)")
      result.should contain("'Service A'")
    end

    it "parses multiple edges" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B\n  B --> C")
      result.should contain("edge(a")
      result.should contain("edge(b")
    end

    it "includes reachability rules in flowchart output" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B")
      result.should contain("reaches(")
    end

    it "handles different arrow styles" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  A --> B\n  C --- D\n  E -.-> F\n  G ==> H")
      result.should contain("edge(a")
      result.should contain("edge(c")
      result.should contain("edge(e")
      result.should contain("edge(g")
    end

    it "parses state transitions" do
      result = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running")
      result.should contain("transition(")
    end

    it "includes can_reach rules for state diagrams" do
      result = Chiasmus::Graph::Mermaid.parse("stateDiagram-v2\n  [*] --> Idle")
      result.should contain("can_reach(")
    end

    it "ignores comments and empty lines" do
      result = Chiasmus::Graph::Mermaid.parse("graph TD\n  %% this is a comment\n  A --> B")
      result.should contain("edge(a")
      result.should_not contain("this is a comment")
    end
  end
end
