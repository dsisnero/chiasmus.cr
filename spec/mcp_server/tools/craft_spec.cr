require "../../spec_helper"
require "file_utils"

def with_craft_server(&)
  dir = File.join(Dir.tempdir, "chiasmus-craft-tool-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)

  with_env({
    "CHIASMUS_HOME" => dir,
  }) do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    begin
      yield server, dir
    ensure
      server.skill_library.close
      Chiasmus::MCPServer.current_server = nil
      FileUtils.rm_rf(dir)
    end
  end
end

describe Chiasmus::MCPServer::Tools::CraftTool do
  it "creates a template via MCP" do
    with_craft_server do |server, _dir|
      tool = Chiasmus::MCPServer::Tools::CraftTool.new

      result = tool.invoke({
        "name"      => JSON::Any.new("mcp-test-template"),
        "domain"    => JSON::Any.new("validation"),
        "solver"    => JSON::Any.new("z3"),
        "signature" => JSON::Any.new("Test template created via MCP"),
        "skeleton"  => JSON::Any.new("(declare-const x Int)\n(assert {{SLOT:condition}})"),
        "slots"     => JSON.parse(%([
          {"name":"condition","description":"Test condition","format":"(> x 0)"}
        ])),
        "normalizations" => JSON.parse(%([
          {"source":"test input","transform":"Map to SMT expression"}
        ])),
      })

      resp = result.as(Chiasmus::MCPServer::Types::CraftResponse)
      resp.created.should be_true
      template = resp.template || raise "Expected template"
      template.should eq("mcp-test-template")
      server.skill_library.get("mcp-test-template").should_not be_nil
    end
  end

  it "returns validation errors for bad input" do
    with_craft_server do |_server, _dir|
      tool = Chiasmus::MCPServer::Tools::CraftTool.new

      result = tool.invoke({
        "name"           => JSON::Any.new(""),
        "domain"         => JSON::Any.new("test"),
        "solver"         => JSON::Any.new("invalid"),
        "signature"      => JSON::Any.new(""),
        "skeleton"       => JSON::Any.new(""),
        "slots"          => JSON.parse(%([])),
        "normalizations" => JSON.parse(%([])),
      })

      result.as(Chiasmus::MCPServer::Types::CraftResponse).created.should be_false
      result.as(Chiasmus::MCPServer::Types::CraftResponse).errors.should_not be_empty
    end
  end

  it "rejects duplicate template name" do
    with_craft_server do |_server, _dir|
      tool = Chiasmus::MCPServer::Tools::CraftTool.new

      # Create first template
      tool.invoke({
        "name"           => JSON::Any.new("unique-name"),
        "domain"         => JSON::Any.new("validation"),
        "solver"         => JSON::Any.new("z3"),
        "signature"      => JSON::Any.new("First template"),
        "skeleton"       => JSON::Any.new("(assert {{SLOT:test}})"),
        "slots"          => JSON.parse(%([{"name":"test","description":"slot","format":"true"}])),
        "normalizations" => JSON.parse(%([{"source":"x","transform":"y"}])),
      })

      # Try creating same name again
      result = tool.invoke({
        "name"           => JSON::Any.new("unique-name"),
        "domain"         => JSON::Any.new("validation"),
        "solver"         => JSON::Any.new("z3"),
        "signature"      => JSON::Any.new("Duplicate"),
        "skeleton"       => JSON::Any.new("(assert {{SLOT:test}})"),
        "slots"          => JSON.parse(%([{"name":"test","description":"slot","format":"true"}])),
        "normalizations" => JSON.parse(%([{"source":"x","transform":"y"}])),
      })

      result.as(Chiasmus::MCPServer::Types::CraftResponse).created.should be_false
      result.as(Chiasmus::MCPServer::Types::CraftResponse).errors.should_not be_empty
    end
  end

  it "provides tool metadata" do
    Chiasmus::MCPServer::Tools::CraftTool.tool_name.should eq("chiasmus_craft")
    Chiasmus::MCPServer::Tools::CraftTool.tool_description.should_not be_empty
    Chiasmus::MCPServer::Tools::CraftTool.input_schema.should_not be_nil
  end
end

describe Chiasmus::Skills do
  describe ".validate_template" do
    valid_input = Chiasmus::Skills::CraftInput.new(
      name: "valid-test-template",
      domain: "validation",
      solver: "z3",
      signature: "A valid test template",
      skeleton: "(assert {{SLOT:condition}})",
      slots: [Chiasmus::Skills::SlotDef.new(name: "condition", description: "The condition", format: "(> x 0)")],
      normalizations: [Chiasmus::Skills::Normalization.new(source: "bool", transform: "Bool")],
    )

    it "valid template passes validation with no errors" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-validate-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          errors = Chiasmus::Skills.validate_template(valid_input, library)
          errors.should be_empty
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "missing required field returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-missing-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "", domain: "test", solver: "z3",
            signature: "s", skeleton: "s",
            slots: valid_input.slots, normalizations: valid_input.normalizations,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any?(&.includes?("required")).should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "invalid solver returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-solver-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "test", domain: "test", solver: "nonsense",
            signature: "s", skeleton: "s",
            slots: valid_input.slots, normalizations: valid_input.normalizations,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any?(&.includes?("solver")).should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "slot in skeleton not in slots array returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-skel-slot-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "test", domain: "test", solver: "z3",
            signature: "s", skeleton: "(assert {{SLOT:missing}})",
            slots: [Chiasmus::Skills::SlotDef.new(name: "other", description: "d", format: "f")],
            normalizations: valid_input.normalizations,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any? { |e| e.includes?("referenced") || e.includes?("not defined") }.should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "slot in array not in skeleton returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-array-slot-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "test", domain: "test", solver: "z3",
            signature: "s", skeleton: "(declare-const x Int)",
            slots: [Chiasmus::Skills::SlotDef.new(name: "unused", description: "d", format: "f")],
            normalizations: valid_input.normalizations,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any?(&.includes?("not referenced")).should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "empty slots array returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-empty-slots-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "test", domain: "test", solver: "z3",
            signature: "s", skeleton: "s",
            slots: [] of Chiasmus::Skills::SlotDef,
            normalizations: valid_input.normalizations,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any?(&.includes?("slots")).should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "empty normalizations array returns error" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-empty-norm-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "test", domain: "test", solver: "z3",
            signature: "s", skeleton: "s",
            slots: valid_input.slots,
            normalizations: [] of Chiasmus::Skills::Normalization,
          )
          errors = Chiasmus::Skills.validate_template(input, library)
          errors.any?(&.includes?("normalizations")).should be_true
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "validation errors prevent creation" do
      with_craft_server do |_server, _dir|
        dir = File.join(Dir.tempdir, "chiasmus-craft-prevent-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(dir)
        library = Chiasmus::Skills::Library.create(dir)
        begin
          input = Chiasmus::Skills::CraftInput.new(
            name: "", domain: "", solver: "",
            signature: "", skeleton: "",
            slots: [] of Chiasmus::Skills::SlotDef,
            normalizations: [] of Chiasmus::Skills::Normalization,
          )
          result = Chiasmus::Skills.craft_template(input, library)
          result.created.should be_false
          errors = result.errors
          errors.should_not be_nil
          (errors || raise("nil errors")).should_not be_empty
        ensure
          library.close
          FileUtils.rm_rf(dir)
        end
      end
    end
  end
end
