require "../../spec_helper"
require "file_utils"

private def with_repo_config_tmp_dir(&)
  dir = File.join(Dir.tempdir, "chiasmus-repo-config-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_current_dir(path : String, &)
  original = Dir.current
  Dir.cd(path)
  begin
    yield
  ensure
    Dir.cd(original)
  end
end

describe Chiasmus::Utils::Config do
  describe ".repo_config_dir" do
    it "returns .chiasmus under the repo root" do
      Chiasmus::Utils::Config.repo_config_dir("/tmp/example-repo").should eq("/tmp/example-repo/.chiasmus")
    end
  end

  describe ".repo_config_path" do
    it "returns config.yml under the repo config directory" do
      Chiasmus::Utils::Config.repo_config_path("/tmp/example-repo").should eq("/tmp/example-repo/.chiasmus/config.yml")
    end
  end

  describe ".load_repo_config" do
    it "creates the repo config directory when it is missing" do
      with_repo_config_tmp_dir do |repo_root|
        config_dir = Chiasmus::Utils::Config.repo_config_dir(repo_root)
        File.exists?(config_dir).should be_false

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)

        config.parity.should be_nil
        Dir.exists?(config_dir).should be_true
        File.exists?(Chiasmus::Utils::Config.repo_config_path(repo_root)).should be_false
      end
    end

    it "loads an existing repo config without requiring parity" do
      with_repo_config_tmp_dir do |repo_root|
        path = Chiasmus::Utils::Config.repo_config_path(repo_root)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, "name: sample\nfeature_flags:\n  search: true\n")

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)

        config.parity.should be_nil
        config.yaml_unmapped["name"].as_s.should eq("sample")
        config.yaml_unmapped["feature_flags"].as_h["search"].as_bool.should be_true
      end
    end
  end

  describe ".ensure_repo_parity_config" do
    it "creates a parity section when repo config is absent" do
      with_repo_config_tmp_dir do |repo_root|
        Chiasmus::Utils::Config.ensure_repo_parity_config(
          vendor_src: "vendor/chiasmus",
          target_src: ["src", "spec"],
          equivalences: [
            Chiasmus::Utils::Config::RepoParityEquivalence.new(
              source_path: "src",
              target_path: "src/chiasmus",
              target_namespace: "Chiasmus"
            ),
          ],
          repo_root: repo_root
        )

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)
        parity = config.parity || raise "expected parity config"
        parity.vendor_src.should eq("vendor/chiasmus")
        parity.target_src.should eq(["src", "spec"])
        parity.equivalences.should_not be_nil
        equivalence = parity.equivalences.not_nil!.first
        equivalence.source_path.should eq("src")
        equivalence.target_path.should eq("src/chiasmus")
        equivalence.target_namespace.should eq("Chiasmus")
      end
    end

    it "adds parity to an existing config without clobbering unrelated keys" do
      with_repo_config_tmp_dir do |repo_root|
        path = Chiasmus::Utils::Config.repo_config_path(repo_root)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, "name: sample\nskills:\n  auto_promote: true\n")

        Chiasmus::Utils::Config.ensure_repo_parity_config(
          vendor_src: "vendor/chiasmus",
          target_src: ["src"],
          equivalences: [
            Chiasmus::Utils::Config::RepoParityEquivalence.new(
              source_path: "tests",
              target_path: "spec/chiasmus",
              target_namespace: "Chiasmus"
            ),
          ],
          repo_root: repo_root
        )

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)
        config.yaml_unmapped["name"].as_s.should eq("sample")
        config.yaml_unmapped["skills"].as_h["auto_promote"].as_bool.should be_true
        parity = config.parity || raise "expected parity config"
        parity.vendor_src.should eq("vendor/chiasmus")
        parity.target_src.should eq(["src"])
        parity.equivalences.not_nil!.map(&.target_path).should eq(["spec/chiasmus"])
      end
    end

    it "fills missing parity fields without overwriting existing values" do
      with_repo_config_tmp_dir do |repo_root|
        path = Chiasmus::Utils::Config.repo_config_path(repo_root)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, "parity:\n  vendor_src: vendor/custom\n  equivalences:\n    - source_path: src\n      target_path: src/custom\n      target_namespace: Custom\n")

        Chiasmus::Utils::Config.ensure_repo_parity_config(
          vendor_src: "vendor/chiasmus",
          target_src: ["src"],
          equivalences: [
            Chiasmus::Utils::Config::RepoParityEquivalence.new(
              source_path: "src",
              target_path: "src/chiasmus",
              target_namespace: "Chiasmus"
            ),
          ],
          repo_root: repo_root
        )

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)
        parity = config.parity || raise "expected parity config"
        parity.vendor_src.should eq("vendor/custom")
        parity.target_src.should eq(["src"])
        parity.equivalences.not_nil!.map(&.target_path).should eq(["src/custom"])
      end
    end

    it "defaults repo root to the current directory" do
      with_repo_config_tmp_dir do |repo_root|
        with_current_dir(repo_root) do
          Chiasmus::Utils::Config.ensure_repo_parity_config(
            vendor_src: "vendor/chiasmus",
            target_src: ["src"],
            equivalences: [
              Chiasmus::Utils::Config::RepoParityEquivalence.new(
                source_path: "src",
                target_path: "src/chiasmus",
                target_namespace: "Chiasmus"
              ),
            ]
          )
        end

        config = Chiasmus::Utils::Config.load_repo_config(repo_root)
        parity = config.parity || raise "expected parity config"
        parity.vendor_src.should eq("vendor/chiasmus")
        parity.target_src.should eq(["src"])
        parity.equivalences.not_nil!.map(&.target_namespace).should eq(["Chiasmus"])
      end
    end
  end
end
