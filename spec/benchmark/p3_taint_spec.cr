require "../spec_helper"

private def swipl_available?
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Benchmark: Problem 3 - Data Flow Taint Analysis" do
  input = {
    edges:   Benchmark::Problems::DataFlowEdges,
    sources: Benchmark::Problems::DataFlowSources,
    sinks:   Benchmark::Problems::DataFlowSinks,
  }

  describe "Traditional" do
    it "finds that http_request can reach db_query" do
      result = Benchmark::Traditional.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "db_query" }
      match.should_not be_nil
    end

    it "finds that http_request can reach eval_engine" do
      result = Benchmark::Traditional.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "eval_engine" }
      match.should_not be_nil
    end

    it "finds that http_request can reach file_write" do
      result = Benchmark::Traditional.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "file_write" }
      match.should_not be_nil
    end

    it "all three sinks are reachable" do
      result = Benchmark::Traditional.solve_taint(input)
      result.reachable.size.should eq(3)
      result.unreachable.size.should eq(0)
    end
  end

  describe "Chiasmus (Prolog)" do
    it "finds that http_request can reach db_query" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "db_query" }
      match.should_not be_nil
    end

    it "finds that http_request can reach eval_engine" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "eval_engine" }
      match.should_not be_nil
    end

    it "finds that http_request can reach file_write" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_taint(input)
      match = result.reachable.find { |r| r[:source] == "http_request" && r[:sink] == "file_write" }
      match.should_not be_nil
    end

    it "all three sinks are reachable" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_taint(input)
      result.reachable.size.should eq(3)
      result.unreachable.size.should eq(0)
    end
  end
end
