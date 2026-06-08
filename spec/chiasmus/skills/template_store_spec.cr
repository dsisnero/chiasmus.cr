require "../../spec_helper"
require "file_utils"

record TestTemplate, name : String, value : String

describe Chiasmus::Skills::InMemoryTemplateStore do
  describe "with SkillTemplate" do
    it "starts empty" do
      store = Chiasmus::Skills::InMemoryTemplateStore(Chiasmus::Skills::SkillTemplate).new
      store.load_all.should be_empty
    end

    it "saves and loads templates" do
      store = Chiasmus::Skills::InMemoryTemplateStore(Chiasmus::Skills::SkillTemplate).new
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "test", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )
      store.save([tpl])
      store.load_all.size.should eq(1)
      store.load_all[0].name.should eq("test")
    end

    it "has? returns true for saved templates" do
      store = Chiasmus::Skills::InMemoryTemplateStore(Chiasmus::Skills::SkillTemplate).new
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "test", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )
      store.has?("test").should be_false
      store.save([tpl])
      store.has?("test").should be_true
    end

    it "deletes templates by name" do
      store = Chiasmus::Skills::InMemoryTemplateStore(Chiasmus::Skills::SkillTemplate).new
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "test", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )
      store.save([tpl])
      store.has?("test").should be_true
      store.delete("test")
      store.has?("test").should be_false
      store.load_all.should be_empty
    end
  end

  describe "generic over TestTemplate" do
    it "works with a different struct type" do
      store = Chiasmus::Skills::InMemoryTemplateStore(TestTemplate).new
      store.save([TestTemplate.new(name: "a", value: "v")])
      store.load_all[0].value.should eq("v")
    end
  end
end

describe Chiasmus::Skills::JsonFileTemplateStore do
  dir = File.join(Dir.tempdir, "chiasmus-tpl-store-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  path = File.join(dir, "templates.json")

  after_all do
    FileUtils.rm_rf(dir)
  end

  describe "with SkillTemplate" do
    it "starts empty when file does not exist" do
      store = Chiasmus::Skills::JsonFileTemplateStore(Chiasmus::Skills::SkillTemplate).new(path)
      store.load_all.should be_empty
    end

    it "saves and loads templates across instances" do
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "persist-test", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )

      store1 = Chiasmus::Skills::JsonFileTemplateStore(Chiasmus::Skills::SkillTemplate).new(path)
      store1.save([tpl])

      store2 = Chiasmus::Skills::JsonFileTemplateStore(Chiasmus::Skills::SkillTemplate).new(path)
      loaded = store2.load_all
      loaded.size.should eq(1)
      loaded[0].name.should eq("persist-test")
      loaded[0].domain.should eq("analysis")
    end

    it "has? checks file-based persistence" do
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "has-test", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )
      store = Chiasmus::Skills::JsonFileTemplateStore(Chiasmus::Skills::SkillTemplate).new(path)
      store.save([tpl])
      store.has?("has-test").should be_true
      store.has?("nonexistent").should be_false
    end

    it "deletes and persists deletion" do
      tpl = Chiasmus::Skills::SkillTemplate.new(
        name: "delete-me", domain: "analysis",
        solver: Chiasmus::Solvers::SolverType::Z3,
        signature: "test", skeleton: "test.",
        slots: [] of Chiasmus::Skills::SlotDef,
        normalizations: [] of Chiasmus::Skills::Normalization,
      )
      store = Chiasmus::Skills::JsonFileTemplateStore(Chiasmus::Skills::SkillTemplate).new(path)
      store.save([tpl])
      store.has?("delete-me").should be_true
      store.delete("delete-me")
      store.has?("delete-me").should be_false
    end
  end
end
