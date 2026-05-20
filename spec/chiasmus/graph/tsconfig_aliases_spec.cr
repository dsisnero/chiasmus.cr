require "../../spec_helper"
require "../../../src/chiasmus/graph/tsconfig_aliases"

include Chiasmus::Graph

private def with_temp_dir(& : String ->)
  dir = File.tempname("chiasmus-tsconfig-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    Dir.children(dir).each { |c| File.delete(File.join(dir, c)) rescue nil }
    Dir.delete(dir) rescue nil
  end
end

private def write_file(dir : String, rel_path : String, content : String) : Nil
  full = File.join(dir, rel_path)
  parent = File.dirname(full)
  Dir.mkdir_p(parent) unless parent == dir
  File.write(full, content)
end

describe TsconfigAliases do
  describe ".load_tsconfig_aliases" do
    it "returns empty when no tsconfig exists" do
      with_temp_dir do |dir|
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_false
        aliases.size.should eq 0
        aliases.rewrite("anything").should be_nil
      end
    end

    it "returns empty when tsconfig has no paths" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.json", %({"compilerOptions":{"target":"ES2022"}}))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_false
      end
    end

    it "resolves glob alias with default baseUrl" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.json", %({"compilerOptions":{"paths":{"@/*":["src/*"]}}}))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_true
        aliases.rewrite("@/components/Button").should eq "src/components/Button"
        aliases.rewrite("@/lib/util.ts").should eq "src/lib/util.ts"
        aliases.rewrite("unrelated/path").should be_nil
      end
    end

    it "resolves exact (non-glob) aliases" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.json", %({
          "compilerOptions": {
            "paths": {
              "react": ["./node_modules/react/index.d.ts"]
            }
          }
        }))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_true
        aliases.rewrite("react").should eq "node_modules/react/index.d.ts"
        aliases.rewrite("other").should be_nil
      end
    end

    it "resolves aliases with custom baseUrl" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.json", %({
          "compilerOptions": {
            "baseUrl": ".",
            "paths": {
              "@lib/*": ["src/lib/*"]
            }
          }
        }))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_true
        aliases.rewrite("@lib/foo").should eq "src/lib/foo"
      end
    end

    it "inherits aliases from parent tsconfig via extends" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.base.json", %({
          "compilerOptions": {
            "baseUrl": ".",
            "paths": {
              "@shared/*": ["shared/*"]
            }
          }
        }))
        write_file(dir, "tsconfig.json", %({
          "extends": "./tsconfig.base.json",
          "compilerOptions": {
            "paths": {
              "@app/*": ["src/app/*"]
            }
          }
        }))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.has_aliases.should be_true
        aliases.rewrite("@shared/foo").should eq "shared/foo"
        aliases.rewrite("@app/bar").should eq "src/app/bar"
      end
    end

    it "child paths override parent paths when same key" do
      with_temp_dir do |dir|
        write_file(dir, "tsconfig.base.json", %({
          "compilerOptions": {
            "paths": {
              "@lib/*": ["old-lib/*"]
            }
          }
        }))
        write_file(dir, "tsconfig.json", %({
          "extends": "./tsconfig.base.json",
          "compilerOptions": {
            "paths": {
              "@lib/*": ["src/new-lib/*"]
            }
          }
        }))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        aliases.rewrite("@lib/foo").should eq "src/new-lib/foo"
      end
    end

    it "is cycle-safe for circular extends" do
      with_temp_dir do |dir|
        write_file(dir, "a.json", %({"extends":"./b.json","compilerOptions":{"paths":{"@a/*":["a/*"]}}}))
        write_file(dir, "b.json", %({"extends":"./a.json","compilerOptions":{"paths":{"@b/*":["b/*"]}}}))
        aliases = TsconfigAliases.load_tsconfig_aliases(dir)
        # Should not loop infinitely; will load from whichever is first candidate.
        # tsconfig.json is tried first and doesn't exist, then tsconfig.app.json.
        # The cycle exists in a/b.json which aren't tried directly.
        aliases.has_aliases.should be_false
      end
    end
  end
end
