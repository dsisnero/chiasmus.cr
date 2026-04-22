require "../../spec_helper"
require "file_utils"

def with_skill_library(&)
  dir = File.join(Dir.tempdir, "chiasmus-skill-library-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  library = Chiasmus::Skills::Library.create(dir)
  begin
    yield library, dir
  ensure
    library.close
    FileUtils.rm_rf(dir)
  end
end

describe Chiasmus::Skills::Library do
  describe "initialization" do
    it "loads all starter templates" do
      with_skill_library do |library, _dir|
        library.list.size.should eq(Chiasmus::Skills::STARTER_TEMPLATES.size)
      end
    end

    it "initializes metadata for all starter templates" do
      with_skill_library do |library, _dir|
        library.list.each do |item|
          item.metadata.reuse_count.should eq(0)
          item.metadata.success_count.should eq(0)
          item.metadata.last_used.should be_nil
          item.metadata.promoted.should be_true
        end
      end
    end
  end

  describe "#search" do
    it "finds policy-contradiction for authorization conflict queries" do
      with_skill_library do |library, _dir|
        results = library.search("do these access control rules conflict or contradict")
        results.should_not be_empty
        results.first.template.name.should eq("policy-contradiction")
      end
    end

    it "finds constraint-satisfaction for dependency version queries" do
      with_skill_library do |library, _dir|
        names = library.search("resolve package version dependency constraints").map(&.template.name)
        names.should contain("constraint-satisfaction")
      end
    end

    it "finds graph-reachability for data flow queries" do
      with_skill_library do |library, _dir|
        names = library.search("can data flow from user input to the database").map(&.template.name)
        names.should contain("graph-reachability")
      end
    end

    it "finds config-equivalence for configuration comparison" do
      with_skill_library do |library, _dir|
        names = library.search("are these two firewall configurations equivalent").map(&.template.name)
        names.should contain("config-equivalence")
      end
    end

    it "finds rule-inference for eligibility and compliance queries" do
      with_skill_library do |library, _dir|
        names = library.search("determine eligibility based on business rules and facts").map(&.template.name)
        names.should contain("rule-inference")
      end
    end

    it "finds permission-derivation for role hierarchy queries" do
      with_skill_library do |library, _dir|
        names = library.search("what can this user do given their role and the permission hierarchy").map(&.template.name)
        names.should contain("permission-derivation")
      end
    end

    it "returns results sorted by descending relevance score" do
      with_skill_library do |library, _dir|
        results = library.search("check authorization policies")
        results.size.should be > 1

        results.each_cons_pair do |left, right|
          left.score.should be >= right.score
        end
      end
    end

    it "filters by domain" do
      with_skill_library do |library, _dir|
        results = library.search("check rules", Chiasmus::Skills::SearchOptions.new(domain: "authorization"))
        results.each do |result|
          result.template.domain.should eq("authorization")
        end
      end
    end

    it "filters by solver type" do
      with_skill_library do |library, _dir|
        results = library.search("check rules", Chiasmus::Skills::SearchOptions.new(solver: Chiasmus::Solvers::SolverType::Prolog))
        results.each do |result|
          result.template.solver.should eq(Chiasmus::Solvers::SolverType::Prolog)
        end
      end
    end
  end

  describe "template structure" do
    it "keeps skeleton slot markers in sync with the declared slots" do
      with_skill_library do |library, _dir|
        library.list.each do |item|
          found_slots = item.template.skeleton.scan(/\{\{SLOT:(\w+)\}\}/).map(&.[1]).to_set
          defined_slots = item.template.slots.map(&.name).to_set

          found_slots.each do |found|
            defined_slots.includes?(found).should be_true, "Template #{item.template.name}: slot #{found} appears in skeleton but is not declared"
          end

          defined_slots.each do |defined|
            found_slots.includes?(defined).should be_true, "Template #{item.template.name}: slot #{defined} is declared but missing from skeleton"
          end
        end
      end
    end

    it "gives every starter template at least one normalization" do
      with_skill_library do |library, _dir|
        library.list.each do |item|
          item.template.normalizations.size.should be > 0, "Template #{item.template.name} has no normalizations"
        end
      end
    end
  end

  describe "metadata tracking" do
    it "records reuse and success counts" do
      with_skill_library do |library, _dir|
        library.record_use("policy-contradiction", true)
        library.record_use("policy-contradiction", true)
        library.record_use("policy-contradiction", false)

        meta = library.get_metadata("policy-contradiction")
        meta.should_not be_nil
        meta.not_nil!.reuse_count.should eq(3)
        meta.not_nil!.success_count.should eq(2)
        meta.not_nil!.last_used.should_not be_nil
      end
    end

    it "persists metadata across library instances" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-persist-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      begin
        library = Chiasmus::Skills::Library.create(dir)
        library.record_use("graph-reachability", true)
        library.close

        reopened = Chiasmus::Skills::Library.create(dir)
        meta = reopened.get_metadata("graph-reachability")
        meta.should_not be_nil
        meta.not_nil!.reuse_count.should eq(1)
        meta.not_nil!.success_count.should eq(1)
        reopened.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#get" do
    it "retrieves a template by exact name" do
      with_skill_library do |library, _dir|
        result = library.get("policy-contradiction")
        result.should_not be_nil
        result.not_nil!.template.name.should eq("policy-contradiction")
      end
    end

    it "returns nil for an unknown name" do
      with_skill_library do |library, _dir|
        library.get("nonexistent").should be_nil
      end
    end
  end
end
