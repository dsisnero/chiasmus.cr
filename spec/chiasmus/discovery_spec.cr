require "spec"
require "../spec_helper"
require "tree_sitter"
require "../../src/chiasmus/discovery"

module Chiasmus
  module Discovery
    # Initialize grammar paths for testing
    def self.init_test_grammars
      vendor_dir = File.expand_path("../../vendor/grammars", __DIR__)
      if Dir.exists?(vendor_dir)
        register_grammar_directory(vendor_dir)
      end
    end
  end
end

# Initialize grammar paths for tests
Chiasmus::Discovery.init_test_grammars

describe Chiasmus::Discovery do
  describe ".detect_parser_available" do
    it "detects tree-sitter available for typescript" do
      available = Chiasmus::Discovery.tree_sitter_available?("typescript")
      available.should be_true
    end

    it "returns false for unsupported language" do
      available = Chiasmus::Discovery.tree_sitter_available?("nonexistent_lang")
      available.should be_false
    end
  end

  describe "class declarations" do
    it "discovers class declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        class MyService {}
        class UserController {}
      TS

      result.parser_mode.should eq("tree-sitter")
      classes = result.items.select { |i| i.kind == "class" }
      classes.map(&.name).should contain("MyService")
      classes.map(&.name).should contain("UserController")
    end

    it "discovers abstract class declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        abstract class BaseHandler {}
      TS

      classes = result.items.select { |i| i.kind == "class" }
      classes.map(&.name).should contain("BaseHandler")
    end

    it "discovers exported class declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        export class ExportedService {}
      TS

      classes = result.items.select { |i| i.kind == "class" }
      classes.map(&.name).should contain("ExportedService")
    end
  end

  describe "interface declarations" do
    it "discovers interface declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        interface UserData {}
        interface RequestConfig {}
      TS

      interfaces = result.items.select { |i| i.kind == "interface" }
      interfaces.map(&.name).should contain("UserData")
      interfaces.map(&.name).should contain("RequestConfig")
    end

    it "discovers exported interface declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        export interface IConfig {}
      TS

      interfaces = result.items.select { |i| i.kind == "interface" }
      interfaces.map(&.name).should contain("IConfig")
    end
  end

  describe "type alias declarations" do
    it "discovers type alias declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        type UserId = string;
        type Callback = () => void;
      TS

      types = result.items.select { |i| i.kind == "type" }
      types.map(&.name).should contain("UserId")
      types.map(&.name).should contain("Callback")
    end
  end

  describe "function declarations" do
    it "discovers function declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        function handleRequest() {}
        function validate() {}
      TS

      functions = result.items.select { |i| i.kind == "function" }
      functions.map(&.name).should contain("handleRequest")
      functions.map(&.name).should contain("validate")
    end

    it "discovers exported function declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        export function main() {}
      TS

      functions = result.items.select { |i| i.kind == "function" }
      functions.map(&.name).should contain("main")
    end

    it "discovers async function declarations" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        async function fetchData() {}
      TS

      functions = result.items.select { |i| i.kind == "function" }
      functions.map(&.name).should contain("fetchData")
    end

    it "discovers arrow functions assigned to variables" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        const handler = () => {};
        const processData = (x: number) => { return x; };
      TS

      functions = result.items.select { |i| i.kind == "function" }
      functions.map(&.name).should contain("handler")
      functions.map(&.name).should contain("processData")
    end
  end

  describe "method definitions" do
    it "discovers methods inside classes with qualified names" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        class MyService {
          handleRequest() {}
          validate() {}
        }
      TS

      methods = result.items.select { |i| i.kind == "method" }
      methods.map(&.name).should contain("MyService.handleRequest")
      methods.map(&.name).should contain("MyService.validate")
    end
  end

  describe "constant declarations" do
    it "discovers UPPERCASE constants only" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        const API_KEY = "secret";
        const MAX_RETRIES = 3;
        const normalVar = "value";
      TS

      consts = result.items.select { |i| i.kind == "const" }
      consts.map(&.name).should contain("API_KEY")
      consts.map(&.name).should contain("MAX_RETRIES")
      consts.map(&.name).should_not contain("normalVar")
    end
  end

  describe "test declarations" do
    it "discovers describe tests" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        describe("UserService", () => {});
      TS

      tests = result.items.select { |i| i.scope == "test" }
      tests.map(&.name).should contain("UserService")
    end

    it "discovers it tests" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        it("should handle requests", () => {});
      TS

      tests = result.items.select { |i| i.scope == "test" }
      tests.map(&.name).should contain("should handle requests")
    end

    it "discovers test blocks" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        test("validate input", () => {});
      TS

      tests = result.items.select { |i| i.scope == "test" }
      tests.map(&.name).should contain("validate input")
    end
  end

  describe "ID format" do
    it "uses stable file-kind-name ID format" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "src/app.ts")
        function hello() {}
        class Foo {}
      TS

      func = result.items.find { |i| i.name == "hello" }
      func.should_not be_nil
      func.not_nil!.id.should eq("src/app.ts::function::hello")

      cls = result.items.find { |i| i.name == "Foo" }
      cls.should_not be_nil
      cls.not_nil!.id.should eq("src/app.ts::class::Foo")
    end
  end

  describe "parser mode tracking" do
    it "reports tree-sitter as parser mode" do
      result = Chiasmus::Discovery.discover_file("typescript", "function foo() {}", "test.ts")
      result.parser_mode.should eq("tree-sitter")
    end
  end

  describe "regex fallback" do
    it "falls back to regex and reports fallback mode when tree-sitter unavailable" do
      result = Chiasmus::Discovery.discover_file(
        "typescript",
        "function foo() {}",
        "test.ts",
        force_parser: "regex"
      )
      result.parser_mode.should eq("regex")
    end
  end

  describe "deduplication" do
    it "does not duplicate items with same ID" do
      result = Chiasmus::Discovery.discover_file("typescript", <<-TS, "test.ts")
        class Foo {}
      TS

      foo_items = result.items.select { |i| i.name == "Foo" }
      foo_items.size.should eq(1)
    end
  end
end
