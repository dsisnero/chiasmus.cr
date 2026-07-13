require "../../spec_helper"

def with_tmp_dir(&)
  dir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def write_config(dir : String, content : String)
  path = File.join(dir, "config.json")
  File.write(path, content)
  path
end

describe Chiasmus::Utils::Config do
  describe ".chiasmus_home" do
    it "returns CHIASMUS_HOME when set" do
      with_env({"CHIASMUS_HOME" => "/explicit/chiasmus/path"}) do
        Chiasmus::Utils::Config.chiasmus_home.should eq("/explicit/chiasmus/path")
      end
    end

    it "returns XDG_CONFIG_HOME/chiasmus when XDG_CONFIG_HOME is set" do
      with_env({
        "CHIASMUS_HOME"   => nil,
        "XDG_CONFIG_HOME" => "/my/xdg/config",
      }) do
        Chiasmus::Utils::Config.chiasmus_home.should eq(File.join("/my/xdg/config", "chiasmus"))
      end
    end

    it "prefers CHIASMUS_HOME over XDG_CONFIG_HOME" do
      with_env({
        "CHIASMUS_HOME"   => "/explicit/path",
        "XDG_CONFIG_HOME" => "/xdg/path",
      }) do
        Chiasmus::Utils::Config.chiasmus_home.should eq("/explicit/path")
      end
    end

    it "defaults to HOME/.config/chiasmus" do
      with_tmp_dir do |dir|
        with_env({
          "HOME"            => dir,
          "CHIASMUS_HOME"   => nil,
          "XDG_CONFIG_HOME" => nil,
        }) do
          Chiasmus::Utils::Config.chiasmus_home.should eq(File.join(dir, ".config", "chiasmus"))
        end
      end
    end

    it "falls back to legacy HOME/.chiasmus when it exists and XDG dir does not" do
      with_tmp_dir do |dir|
        legacy_dir = File.join(dir, ".chiasmus")
        Dir.mkdir_p(legacy_dir)

        with_env({
          "HOME"            => dir,
          "CHIASMUS_HOME"   => nil,
          "XDG_CONFIG_HOME" => nil,
        }) do
          Chiasmus::Utils::Config.chiasmus_home.should eq(legacy_dir)
        end
      end
    end

    it "prefers XDG dir when both XDG and legacy dirs exist" do
      with_tmp_dir do |dir|
        xdg_dir = File.join(dir, ".config", "chiasmus")
        legacy_dir = File.join(dir, ".chiasmus")
        Dir.mkdir_p(xdg_dir)
        Dir.mkdir_p(legacy_dir)

        with_env({
          "HOME"            => dir,
          "CHIASMUS_HOME"   => nil,
          "XDG_CONFIG_HOME" => nil,
        }) do
          Chiasmus::Utils::Config.chiasmus_home.should eq(xdg_dir)
        end
      end
    end

    it "raises when HOME is not set" do
      with_env({
        "HOME"            => nil,
        "CHIASMUS_HOME"   => nil,
        "XDG_CONFIG_HOME" => nil,
      }) do
        expect_raises(Exception, "HOME environment variable not set") do
          Chiasmus::Utils::Config.chiasmus_home
        end
      end
    end
  end

  describe ".load" do
    it "returns defaults when config.json does not exist" do
      config = Chiasmus::Utils::Config.load("/nonexistent/path")
      config.should be_a(Chiasmus::Utils::Config::ChiasmusConfig)
    end

    it "falls back to defaults for invalid JSON" do
      with_tmp_dir do |dir|
        write_config(dir, "not valid json {{{")
        config = Chiasmus::Utils::Config.load(dir)
        config.should be_a(Chiasmus::Utils::Config::ChiasmusConfig)
      end
    end

    it "ignores unknown keys and wrong types" do
      with_tmp_dir do |dir|
        write_config(dir, %({"unknownKey":42}))
        config = Chiasmus::Utils::Config.load(dir)
        config.should be_a(Chiasmus::Utils::Config::ChiasmusConfig)
      end
    end

    it "returns defaults for empty JSON object" do
      with_tmp_dir do |dir|
        write_config(dir, "{}")
        config = Chiasmus::Utils::Config.load(dir)
        config.should be_a(Chiasmus::Utils::Config::ChiasmusConfig)
      end
    end

    it "returns defaults for whitespace-only JSON file" do
      with_tmp_dir do |dir|
        write_config(dir, "   \n  \t  ")
        config = Chiasmus::Utils::Config.load(dir)
        config.should be_a(Chiasmus::Utils::Config::ChiasmusConfig)
      end
    end
  end

  describe ".save" do
    it "writes valid JSON to config.json" do
      with_tmp_dir do |dir|
        config = Chiasmus::Utils::Config::ChiasmusConfig.new
        Chiasmus::Utils::Config.save(config, dir)
        raw = File.read(File.join(dir, "config.json"))
        JSON.parse(raw).as_h.should be_empty
      end
    end

    it "creates parent directory when it does not exist" do
      with_tmp_dir do |dir|
        nested = File.join(dir, "deeply", "nested", "config")
        config = Chiasmus::Utils::Config::ChiasmusConfig.new
        Chiasmus::Utils::Config.save(config, nested)
        File.exists?(File.join(nested, "config.json")).should be_true
        Dir.exists?(nested).should be_true
      end
    end

    it "round-trips: save then load returns identical config" do
      with_tmp_dir do |dir|
        original = Chiasmus::Utils::Config::ChiasmusConfig.new
        Chiasmus::Utils::Config.save(original, dir)
        loaded = Chiasmus::Utils::Config.load(dir)
        loaded.should eq(original)
      end
    end

    it "overwrites existing config.json" do
      with_tmp_dir do |dir|
        write_config(dir, %({"obsolete":true}))
        config = Chiasmus::Utils::Config::ChiasmusConfig.new
        Chiasmus::Utils::Config.save(config, dir)
        JSON.parse(File.read(File.join(dir, "config.json"))).as_h.should be_empty
      end
    end
  end
end
