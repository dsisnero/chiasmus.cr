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
        if meta
          meta.reuse_count.should eq(3)
          meta.success_count.should eq(2)
          meta.last_used.should_not be_nil
        end
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
        if meta
          meta.reuse_count.should eq(1)
          meta.success_count.should eq(1)
        end
        reopened.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "records concurrent usage without dropping increments" do
      with_skill_library do |library, _dir|
        start = Channel(Nil).new
        done = Channel(Nil).new
        workers = 16

        workers.times do
          spawn do
            start.receive
            library.record_use("policy-contradiction", true)
            done.send(nil)
          end
        end

        workers.times { start.send(nil) }
        workers.times { done.receive }

        meta = library.get_metadata("policy-contradiction")
        meta.should_not be_nil
        if meta
          meta.reuse_count.should eq(workers)
          meta.success_count.should eq(workers)
        end
      end
    end

    it "does not block record_use on metadata persistence" do
      with_skill_library do |library, _dir|
        entered = Channel(Bool).new(1)
        release = Channel(Bool).new(1)
        returned = Channel(Bool).new(1)

        begin
          Chiasmus::Skills::Library.set_before_metadata_write_hook_for_test do
            entered.send(true)
            release.receive
          end

          spawn do
            library.record_use("policy-contradiction", true)
            returned.send(true)
          end

          entered.receive.should be_true

          select
          when value = returned.receive?
            value.should be_true
          when timeout 250.milliseconds
            fail("expected record_use to return before metadata persistence finished")
          end
        ensure
          release.send(true) rescue nil
          Chiasmus::Skills::Library.clear_before_metadata_write_hook_for_test
        end
      end
    end

    it "flushes pending metadata persistence on close" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-close-flush-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)

      begin
        library = Chiasmus::Skills::Library.create(dir)

        begin
          Chiasmus::Skills::Library.set_before_metadata_write_hook_for_test do
            entered.send(true)
            release.receive
          end

          library.record_use("graph-reachability", true)
          entered.receive.should be_true

          close_done = Channel(Bool).new(1)
          spawn do
            library.close
            close_done.send(true)
          end

          select
          when close_done.receive?
            fail("expected close to wait for pending metadata persistence")
          when timeout 100.milliseconds
          end

          release.send(true)
          close_done.receive.should be_true
        ensure
          Chiasmus::Skills::Library.clear_before_metadata_write_hook_for_test
        end

        reopened = Chiasmus::Skills::Library.create(dir)
        meta = reopened.get_metadata("graph-reachability")
        meta.should_not be_nil
        meta.not_nil!.reuse_count.should eq(1)
        reopened.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "does not block promote on metadata persistence" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-promote-async-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)
      returned = Channel(Bool).new(1)

      begin
        template = Chiasmus::Skills::SkillTemplate.new(
          name: "promote-async",
          domain: "analysis",
          solver: Chiasmus::Solvers::SolverType::Prolog,
          signature: "test promote async",
          skeleton: "test.",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "test", transform: "test"),
          ],
        )

        library = Chiasmus::Skills::Library.create(dir)
        library.add_learned(template).should be_true

        begin
          Chiasmus::Skills::Library.set_before_metadata_write_hook_for_test do
            entered.send(true)
            release.receive
          end

          spawn do
            returned.send(library.promote("promote-async"))
          end

          entered.receive.should be_true

          select
          when value = returned.receive?
            value.should be_true
          when timeout 250.milliseconds
            fail("expected promote to return before metadata persistence finished")
          end
        ensure
          release.send(true) rescue nil
          Chiasmus::Skills::Library.clear_before_metadata_write_hook_for_test
        end

        library.close
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
        if result
          result.template.name.should eq("policy-contradiction")
        end
      end
    end

    it "returns nil for an unknown name" do
      with_skill_library do |library, _dir|
        library.get("nonexistent").should be_nil
      end
    end
  end

  describe "learned template persistence" do
    it "add_learned returns false when the name already exists" do
      with_skill_library do |library, _dir|
        result = library.add_learned(Chiasmus::Skills::SkillTemplate.new(
          name: "policy-contradiction",
          domain: "authorization",
          solver: Chiasmus::Solvers::SolverType::Z3,
          signature: "test",
          skeleton: "test",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [] of Chiasmus::Skills::Normalization,
        ))
        result.should be_false
      end
    end

    it "persists learned templates across library instances" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-persist-tpl-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      begin
        tpl = Chiasmus::Skills::SkillTemplate.new(
          name: "custom-auth-check",
          domain: "authorization",
          solver: Chiasmus::Solvers::SolverType::Z3,
          signature: "verify custom authorization rules",
          skeleton: "(declare-const user Bool)\n(assert user)",
          slots: [
            Chiasmus::Skills::SlotDef.new(name: "user", description: "the user var", format: "bool"),
          ],
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "bool", transform: "Bool"),
          ],
          tips: ["use declare-const"],
          example: "(declare-const x Bool)\n(assert x)",
        )

        lib1 = Chiasmus::Skills::Library.create(dir)
        lib1.add_learned(tpl).should be_true
        lib1.close

        lib2 = Chiasmus::Skills::Library.create(dir)
        restored = lib2.get("custom-auth-check")
        restored.should_not be_nil
        if r = restored
          r.template.name.should eq("custom-auth-check")
          r.template.domain.should eq("authorization")
          r.template.skeleton.should eq("(declare-const user Bool)\n(assert user)")
          r.template.slots.size.should eq(1)
          r.template.normalizations.size.should eq(1)
          r.template.tips.should eq(["use declare-const"])
          r.template.example.should eq("(declare-const x Bool)\n(assert x)")
          r.metadata.promoted.should be_false
          r.metadata.reuse_count.should eq(0)
        end
        lib2.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "persists promoted state across library instances" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-promote-persist-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      begin
        tpl = Chiasmus::Skills::SkillTemplate.new(
          name: "to-promote",
          domain: "analysis",
          solver: Chiasmus::Solvers::SolverType::Prolog,
          signature: "test promote",
          skeleton: "test.",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "test", transform: "test"),
          ],
        )

        lib1 = Chiasmus::Skills::Library.create(dir)
        lib1.add_learned(tpl)
        lib1.promote("to-promote").should be_true
        lib1.close

        lib2 = Chiasmus::Skills::Library.create(dir)
        restored = lib2.get("to-promote")
        restored.should_not be_nil
        if restored
          restored.metadata.promoted.should be_true
        end
        lib2.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "remove() deletes the template from disk" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-remove-persist-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      begin
        tpl = Chiasmus::Skills::SkillTemplate.new(
          name: "to-remove",
          domain: "analysis",
          solver: Chiasmus::Solvers::SolverType::Prolog,
          signature: "test remove",
          skeleton: "test.",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "test", transform: "test"),
          ],
        )

        lib1 = Chiasmus::Skills::Library.create(dir)
        lib1.add_learned(tpl)
        lib1.get("to-remove").should_not be_nil
        lib1.remove("to-remove")
        lib1.get("to-remove").should be_nil
        lib1.close

        lib2 = Chiasmus::Skills::Library.create(dir)
        lib2.get("to-remove").should be_nil
        lib2.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "reloaded templates are searchable" do
      dir = File.join(Dir.tempdir, "chiasmus-skill-library-search-persist-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)

      begin
        tpl = Chiasmus::Skills::SkillTemplate.new(
          name: "searchable-custom",
          domain: "dependency",
          solver: Chiasmus::Solvers::SolverType::Z3,
          signature: "resolve package dependency constraints for npm",
          skeleton: "(declare-const pkg Bool)\n(assert pkg)",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "bool", transform: "Bool"),
          ],
        )

        lib1 = Chiasmus::Skills::Library.create(dir)
        lib1.add_learned(tpl)
        lib1.close

        lib2 = Chiasmus::Skills::Library.create(dir)
        results = lib2.search("package dependency constraints")
        names = results.map(&.template.name)
        names.should contain("searchable-custom")
        lib2.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "cannot promote a nonexistent template name" do
      with_skill_library do |library, _dir|
        library.promote("nonexistent").should be_false
      end
    end

    it "allows only one concurrent learned insert for the same name" do
      with_skill_library do |library, _dir|
        template = Chiasmus::Skills::SkillTemplate.new(
          name: "concurrent-template",
          domain: "analysis",
          solver: Chiasmus::Solvers::SolverType::Prolog,
          signature: "test concurrent insert",
          skeleton: "test.",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "test", transform: "test"),
          ],
        )

        start = Channel(Nil).new
        results = Channel(Bool).new

        2.times do
          spawn do
            start.receive
            results.send(library.add_learned(template))
          end
        end

        2.times { start.send(nil) }
        outcomes = [results.receive, results.receive]

        outcomes.count(true).should eq(1)
        library.get("concurrent-template").should_not be_nil
      end
    end

    it "candidates returns only non-promoted templates" do
      with_skill_library do |library, _dir|
        tpl = Chiasmus::Skills::SkillTemplate.new(
          name: "candidate-test",
          domain: "analysis",
          solver: Chiasmus::Solvers::SolverType::Prolog,
          signature: "test candidates",
          skeleton: "test.",
          slots: [] of Chiasmus::Skills::SlotDef,
          normalizations: [
            Chiasmus::Skills::Normalization.new(source: "test", transform: "test"),
          ],
        )
        library.add_learned(tpl)
        cands = library.candidates
        names = cands.map(&.template.name)
        names.should contain("candidate-test")
        names.should_not contain("policy-contradiction")
      end
    end
  end

  describe "#get_template_search_text" do
    it "produces searchable text that includes signature and slots but not tips" do
      with_skill_library do |library, _dir|
        skill = library.get("policy-contradiction")
        raise "Expected policy-contradiction to be present" unless skill
        template = skill.template
        text = library.get_template_search_text(template)
        text.should be_a(String)
        text.should_not be_empty
        text.should contain(template.name)
        text.should contain(template.domain)
        text.should contain(template.signature)
        template.slots.each do |slot|
          text.should contain(slot.description)
        end
        template.normalizations.each do |norm|
          text.should contain(norm.source)
          text.should contain(norm.transform)
        end
        if tips = template.tips
          tips.each do |tip|
            text.should_not contain(tip)
          end
        end
      end
    end
  end
end
