require "../../spec_helper"
require "../../../src/chiasmus/graph/suffix_index"

include Chiasmus::Graph

REPO = "/repo"

private def f(p : String) : String
  "#{REPO}/#{p}"
end

describe SuffixIndex do
  describe ".build" do
    it "indexes files and looks up exact matches" do
      idx = SuffixIndex.build(REPO, [f("src/a.ts"), f("src/b.ts")])
      idx.size.should be > 0
      idx.has_module_qn?("src/a.ts").should be_true
      idx.has_module_qn?("src/b.ts").should be_true
      idx.has_module_qn?("src/c.ts").should be_false
    end

    it "ignores files outside the repo" do
      idx = SuffixIndex.build(REPO, ["/somewhere-else/file.ts", f("src/real.ts")])
      idx.has_module_qn?("src/real.ts").should be_true
    end
  end

  describe "#resolve_import" do
    it "returns nil when the index is empty" do
      r = SuffixIndex.empty.resolve_import("./foo", nil)
      r.should be_nil
    end

    it "resolves an import to a .ts file" do
      idx = SuffixIndex.build(REPO, [f("src/lib/foo.ts"), f("src/lib/bar.ts")])
      idx.resolve_import("./foo", nil).should eq "src/lib/foo.ts"
      idx.resolve_import("lib/foo", nil).should eq "src/lib/foo.ts"
    end

    it "resolves a directory import to its index file" do
      idx = SuffixIndex.build(REPO, [f("src/lib/index.ts")])
      idx.resolve_import("./lib", nil).should eq "src/lib/index.ts"
    end

    it "resolves .js imports to .ts files (ESM convention)" do
      idx = SuffixIndex.build(REPO, [f("src/utils.ts")])
      idx.resolve_import("./utils.js", nil).should eq "src/utils.ts"
    end

    it "prefers .ts over .js when both exist" do
      idx = SuffixIndex.build(REPO, [f("src/both.ts"), f("src/both.js")])
      resolved = idx.resolve_import("./both", nil)
      resolved.should eq "src/both.ts"
    end

    it "uses primary guess when provided" do
      idx = SuffixIndex.build(REPO, [
        f("src/components/Button.tsx"),
        f("src/components/Button.test.tsx"),
      ])
      resolved = idx.resolve_import("./Button", "src/components/Button")
      resolved.should eq "src/components/Button.tsx"
    end

    it "returns nil when the suffix does not match any indexed file" do
      idx = SuffixIndex.build(REPO, [f("src/a.ts")])
      idx.resolve_import("nonexistent/path", nil).should be_nil
    end

    it "falls back through shorter suffixes" do
      idx = SuffixIndex.build(REPO, [f("packages/core/src/util.ts")])
      # "packages/core/src/util" matches; any shorter suffix also does.
      idx.resolve_import("core/src/util", nil).should eq "packages/core/src/util.ts"
      idx.resolve_import("src/util", nil).should eq "packages/core/src/util.ts"
      idx.resolve_import("util", nil).should eq "packages/core/src/util.ts"
    end
  end
end
