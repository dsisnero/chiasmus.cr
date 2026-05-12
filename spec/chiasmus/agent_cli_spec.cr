require "spec"
require "json"
require "../../src/chiasmus"

private def parse(args : Array(String)) : Chiasmus::AgentCLI::Options
  Chiasmus::AgentCLI.parse(args)
end

private def with_tempfile(content : String, & : String ->)
  path = File.tempname("agent_cli_spec", ".ts")
  File.write(path, content)
  begin
    yield path
  ensure
    File.delete(path)
  end
end

describe Chiasmus::AgentCLI do
  describe ".parse" do
    it "parses ask mode with a question" do
      opts = parse(["ask", "what is x > 5?"])
      opts.mode.should eq(:ask)
      opts.question.should eq("what is x > 5?")
      opts.code_files.should be_empty
    end

    it "parses repl mode" do
      opts = parse(["repl"])
      opts.mode.should eq(:repl)
      opts.question.should be_nil
    end

    it "parses --code with a file path" do
      opts = parse(["--code", "src/main.ts", "ask", "find unused functions"])
      opts.mode.should eq(:ask)
      opts.code_files.should eq(["src/main.ts"])
      opts.question.should eq("find unused functions")
    end

    it "parses --code with multiple file paths" do
      opts = parse(["--code", "a.ts", "--code", "b.ts", "ask", "find callers of query"])
      opts.code_files.should eq(["a.ts", "b.ts"])
    end

    it "parses --provider" do
      opts = parse(["--provider", "deepseek", "ask", "test"])
      opts.provider.should eq("deepseek")
    end

    it "parses --model" do
      opts = parse(["--model", "deepseek-chat", "ask", "test"])
      opts.model.should eq("deepseek-chat")
    end

    it "parses --api-key" do
      opts = parse(["--api-key", "sk-xxx", "ask", "test"])
      opts.api_key.should eq("sk-xxx")
    end

    it "defaults mode to ask when no subcommand is given" do
      opts = parse(["default question here"])
      opts.mode.should eq(:ask)
      opts.question.should eq("default question here")
    end

    it "shows help with --help" do
      expect_raises(OptionParser::Exception, /help/) do
        parse(["--help"])
      end
    end

    it "shows version with --version" do
      expect_raises(OptionParser::Exception, /version/i) do
        parse(["--version"])
      end
    end

    it "exits with error when ask has no question" do
      expect_raises(OptionParser::Exception, /question/) do
        parse(["ask"])
      end
    end

    it "treats unknown subcommand as an ask question" do
      opts = parse(["nonsense"])
      opts.mode.should eq(:ask)
      opts.question.should eq("nonsense")
    end

    it "parses --json output flag" do
      opts = parse(["--json", "ask", "test"])
      opts.json?.should be_true
    end

    it "parses --debug flag" do
      opts = parse(["--debug", "ask", "test"])
      opts.debug?.should be_true
    end
  end

  describe ".build_agent" do
    if ENV["DEEPSEEK_API_KEY"]?
      it "builds an agent from options" do
        opts = Chiasmus::AgentCLI::Options.new(
          provider: "deepseek",
          api_key: ENV["DEEPSEEK_API_KEY"],
          model: "deepseek-chat",
        )
        agent = Chiasmus::AgentCLI.build_agent(opts)
        agent.should_not be_nil
      end
    else
      pending "builds an agent from options (requires DEEPSEEK_API_KEY)"
    end
  end

  describe ".run_graph_analysis" do
    it "analyses code files and returns summary" do
      with_tempfile("function a() { b(); }\nfunction b() {}\nexport function a() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "summary"
        )

        result.should contain("files")
        result.should contain("functions")
        JSON.parse(result)["result"]["files"].as_i.should eq(1)
      end
    end

    it "analyses code files and returns callers" do
      with_tempfile("function a() { b(); }\nfunction b() { c(); }\nfunction c() {}\nexport function a() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "callers of c"
        )

        parsed = JSON.parse(result)
        parsed["analysis"].as_s.should eq("callers")
        parsed["target"].as_s.should eq("c")
        parsed["result"].as_a.should contain("b")
      end
    end

    it "analyses code files and returns dead code" do
      with_tempfile("function main() { used(); }\nfunction used() {}\nfunction unusedFunc() {}\nexport function main() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "dead code"
        )

        parsed = JSON.parse(result)
        parsed["analysis"].as_s.should eq("dead-code")
        parsed["result"].as_a.should contain("unusedFunc")
      end
    end

    it "analyses code files and returns reachability" do
      with_tempfile("function a() { b(); }\nfunction b() { c(); }\nfunction c() {}\nexport function a() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "can a reach c?"
        )

        parsed = JSON.parse(result)
        parsed["analysis"].as_s.should eq("reachability")
        parsed["from"].as_s.should eq("a")
        parsed["to"].as_s.should eq("c")
        parsed["result"].as_h["reachable"].as_bool.should be_true
      end
    end

    it "analyses code files and returns impact" do
      with_tempfile("function main() { handler(); }\nfunction handler() { validate(); }\nfunction validate() { query(); }\nfunction query() {}\nexport function main() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "who is affected if query changes?"
        )

        parsed = JSON.parse(result)
        parsed["analysis"].as_s.should eq("impact")
        parsed["target"].as_s.should eq("query")
        parsed["result"].as_a.should contain("validate")
        parsed["result"].as_a.should contain("handler")
        parsed["result"].as_a.should contain("main")
      end
    end

    it "returns facts in Prolog format" do
      with_tempfile("function a() { b(); }\nfunction b() {}\nexport function a() {}\n") do |path|
        result = Chiasmus::AgentCLI.run_graph_analysis(
          [path], "facts"
        )

        parsed = JSON.parse(result)
        parsed["analysis"].as_s.should eq("facts")
        parsed["result"].as_s.should contain("defines(")
        parsed["result"].as_s.should contain("calls(")
      end
    end

    it "returns error for unknown graph question" do
      result = Chiasmus::AgentCLI.run_graph_analysis(
        [] of String, "some random question"
      )

      JSON.parse(result)["status"].as_s.should eq("error")
    end

    it "returns error when no code files provided" do
      result = Chiasmus::AgentCLI.run_graph_analysis(
        [] of String, "summary"
      )

      JSON.parse(result)["status"].as_s.should eq("error")
    end
  end

  describe ".question_to_graph_analysis" do
    it "parses 'callers of X'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("callers of query")
      result = result.should_not be_nil
      result[:analysis].should eq("callers")
      result[:target].should eq("query")
    end

    it "parses 'callees of X'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("callees of main")
      result = result.should_not be_nil
      result[:analysis].should eq("callees")
      result[:target].should eq("main")
    end

    it "parses 'can X reach Y?'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("can a reach c?")
      result = result.should_not be_nil
      result[:analysis].should eq("reachability")
      result[:from].should eq("a")
      result[:to].should eq("c")
    end

    it "parses 'is X reachable from Y?'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("is c reachable from a?")
      result = result.should_not be_nil
      result[:analysis].should eq("reachability")
      result[:from].should eq("a")
      result[:to].should eq("c")
    end

    it "parses 'dead code' and 'deadcode'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("dead code")
      result = result.should_not be_nil
      result[:analysis].should eq("dead-code")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("deadcode")
      result = result.should_not be_nil
      result[:analysis].should eq("dead-code")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("find dead code")
      result = result.should_not be_nil
      result[:analysis].should eq("dead-code")
    end

    it "parses 'cycles'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("cycles")
      result = result.should_not be_nil
      result[:analysis].should eq("cycles")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("find cycles")
      result = result.should_not be_nil
      result[:analysis].should eq("cycles")
    end

    it "parses 'path from X to Y'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("path from a to c")
      result = result.should_not be_nil
      result[:analysis].should eq("path")
      result[:from].should eq("a")
      result[:to].should eq("c")
    end

    it "parses 'impact of X' and 'who is affected if X changes'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("impact of query")
      result = result.should_not be_nil
      result[:analysis].should eq("impact")
      result[:target].should eq("query")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("who is affected if query changes")
      result = result.should_not be_nil
      result[:analysis].should eq("impact")
      result[:target].should eq("query")
    end

    it "parses 'summary'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("summary")
      result = result.should_not be_nil
      result[:analysis].should eq("summary")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("summarize")
      result = result.should_not be_nil
      result[:analysis].should eq("summary")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("show summary")
      result = result.should_not be_nil
      result[:analysis].should eq("summary")
    end

    it "parses 'facts'" do
      result = Chiasmus::AgentCLI.question_to_graph_analysis("facts")
      result = result.should_not be_nil
      result[:analysis].should eq("facts")

      result = Chiasmus::AgentCLI.question_to_graph_analysis("prolog facts")
      result = result.should_not be_nil
      result[:analysis].should eq("facts")
    end

    it "returns nil for unparseable questions" do
      Chiasmus::AgentCLI.question_to_graph_analysis("some random question").should be_nil
    end
  end

  describe ".format_output" do
    it "formats summary output" do
      result = %({"status":"success","analysis":"summary","result":{"files":2,"functions":3,"classes":1,"callEdges":2,"imports":1,"exports":1}})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("Summary")
      formatted.should contain("files: 2")
      formatted.should contain("functions: 3")
    end

    it "formats callers output" do
      result = %({"status":"success","analysis":"callers","target":"query","result":["validate","main"]})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("Callers of")
      formatted.should contain("- validate")
      formatted.should contain("- main")
    end

    it "formats dead-code output" do
      result = %({"status":"success","analysis":"dead-code","result":["unusedFunc"]})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("Dead Code")
      formatted.should contain("- unusedFunc")
    end

    it "formats reachability output" do
      result = %({"status":"success","analysis":"reachability","from":"a","to":"c","result":{"reachable":true}})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("a")
      formatted.should contain("c")
      formatted.should contain("reachable")
    end

    it "formats JSON output" do
      result = %({"status":"success","analysis":"summary","result":{"files":1}})
      formatted = Chiasmus::AgentCLI.format_output(result, json: true)
      parsed = JSON.parse(formatted)
      parsed["analysis"].as_s.should eq("summary")
    end

    it "formats error output" do
      result = %({"status":"error","error":"something went wrong"})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("Error")
      formatted.should contain("something went wrong")
    end

    it "formats formal solve output" do
      result = %({"status":"success","solver":"z3","satisfiable":true,"model":{"x":"5"},"template":"constraint-satisfaction"})
      formatted = Chiasmus::AgentCLI.format_output(result, json: false)
      formatted.should contain("Formal Verification")
      formatted.should contain("z3")
      formatted.should contain("Satisfiable")
    end
  end
end
