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
      config.adapter_discovery.should be_false
    end

    it "reads adapterDiscovery from config.json" do
      with_tmp_dir do |dir|
        write_config(dir, %({"adapterDiscovery":true}))
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_true
      end
    end

    it "falls back to defaults for invalid JSON" do
      with_tmp_dir do |dir|
        write_config(dir, "not valid json {{{")
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "ignores unknown keys and wrong types" do
      with_tmp_dir do |dir|
        write_config(dir, %({"adapterDiscovery":"yes","unknownKey":42}))
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "returns defaults when config.json contains null for adapterDiscovery" do
      with_tmp_dir do |dir|
        write_config(dir, %({"adapterDiscovery":null}))
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "returns defaults for empty JSON object" do
      with_tmp_dir do |dir|
        write_config(dir, "{}")
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "returns defaults when adapterDiscovery key is missing" do
      with_tmp_dir do |dir|
        write_config(dir, %({"someOtherKey":123}))
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "returns defaults for whitespace-only JSON file" do
      with_tmp_dir do |dir|
        write_config(dir, "   \n  \t  ")
        config = Chiasmus::Utils::Config.load(dir)
        config.adapter_discovery.should be_false
      end
    end

    it "returns fresh copies from DEFAULTS.dup" do
      config1 = Chiasmus::Utils::Config.load("/nonexistent/path")
      config2 = Chiasmus::Utils::Config.load("/nonexistent/path")
      config1.adapter_discovery.should be_false
      config2.adapter_discovery.should be_false
    end
  end

  describe ".save" do
    it "writes valid JSON with the correct key to config.json" do
      with_tmp_dir do |dir|
        config = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: true)
        Chiasmus::Utils::Config.save(config, dir)
        raw = File.read(File.join(dir, "config.json"))
        JSON.parse(raw)["adapterDiscovery"].as_bool.should be_true
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
        original = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: true)
        Chiasmus::Utils::Config.save(original, dir)
        loaded = Chiasmus::Utils::Config.load(dir)
        loaded.adapter_discovery.should be_true
      end
    end

    it "round-trips default config (false)" do
      with_tmp_dir do |dir|
        original = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: false)
        Chiasmus::Utils::Config.save(original, dir)
        loaded = Chiasmus::Utils::Config.load(dir)
        loaded.adapter_discovery.should be_false
      end
    end

    it "overwrites existing config.json" do
      with_tmp_dir do |dir|
        write_config(dir, %({"adapterDiscovery":false}))
        config = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: true)
        Chiasmus::Utils::Config.save(config, dir)
        loaded = Chiasmus::Utils::Config.load(dir)
        loaded.adapter_discovery.should be_true
      end
    end
  end

  describe Chiasmus::Utils::Config::ChiasmusConfig do
    it "defaults adapter_discovery to false" do
      config = Chiasmus::Utils::Config::ChiasmusConfig.new
      config.adapter_discovery.should be_false
    end

    it "can be constructed with adapter_discovery: true" do
      config = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: true)
      config.adapter_discovery.should be_true
    end
  end
end
