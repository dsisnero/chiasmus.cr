require "spec"
require "mcp"
require "json"
require "file_utils"
require "../../support/mcp_test_harness"

describe "MCP Transport-Level Harness" do
  harness = Chiasmus::MCPTestHarness::Instance.new(
    ["chiasmus_verify", "chiasmus_graph"]
  )

  before_all do
    harness.register_all_tools
    harness.connect
  end

  after_all do
    # InMemoryTransport close can hang; skip for now
  end

  describe "tools/list" do
    it "returns registered tools with correct names" do
      names = harness.list_tools
      names.should contain("chiasmus_verify")
      names.should contain("chiasmus_graph")
    end

    it "tools have descriptions via ListToolsResult" do
      result = harness.client.list_tools.not_nil!
      verify_tool = result.tools.find { |t| t.name == "chiasmus_verify" }
      verify_tool.should_not be_nil
      verify_tool.not_nil!.description.should be_a(String)
    end
  end

  describe "chiasmus_verify tool" do
    it "returns valid for tautology" do
      result = harness.call_tool("chiasmus_verify", {
        "input"  => JSON::Any.new("forall x: x = x"),
        "solver" => JSON::Any.new("z3"),
      })
      result["status"].as_s.should eq("success")
    end

    it "returns error for missing parameters" do
      result = harness.call_tool("chiasmus_verify", {} of String => JSON::Any)
      result["error"]?.should_not be_nil
    end
  end

  describe "chiasmus_graph tool" do
    temp_dir = ""
    src_dir = ""

    before_all do
      temp_dir = File.tempname("chiasmus-transport-graph-")
      Dir.mkdir_p(temp_dir)
      src_dir = File.join(temp_dir, "src")
      Dir.mkdir_p(src_dir)
      File.write(File.join(src_dir, "server.ts"), <<-TS)
        export function handleRequest() { validate(); }
        function validate() {}
      TS
    end

    after_all do
      harness.close rescue nil
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end

    it "returns summary via transport" do
      result = harness.call_tool("chiasmus_graph", {
        "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts"))]),
        "analysis" => JSON::Any.new("summary"),
      })
      result["status"].as_s.should eq("success")
      result["analysis"].as_s.should eq("summary")
    end

    it "has valid analysis enum in schema" do
      expected = ["summary", "callers", "callees", "reachability", "dead-code", "cycles", "path", "impact", "facts"]
      input = Chiasmus::MCPServer::Tools::GraphTool.input_schema
      enum_values = input.properties["analysis"]["enum"].as_a.map(&.as_s)
      enum_values.should eq(expected)
    end
  end

  describe "transport-level error handling" do
    it "returns error for unknown tool" do
      expect_raises(Exception) do
        harness.client.call_tool("nonexistent_tool_xyz", {} of String => JSON::Any)
      end
    end
  end
end
