require "./spec_helper"

describe Chiasmus::Utils::Config do
  describe ".load" do
    it "returns defaults when config.json does not exist" do
      tmpdir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      begin
        config = Chiasmus::Utils::Config.load(tmpdir)
        config.adapter_discovery.should be_false
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "reads adapterDiscovery from config.json" do
      tmpdir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "config.json"), %({"adapterDiscovery": true}))
      begin
        config = Chiasmus::Utils::Config.load(tmpdir)
        config.adapter_discovery.should be_true
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "falls back to defaults for invalid JSON" do
      tmpdir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "config.json"), "not valid json")
      begin
        config = Chiasmus::Utils::Config.load(tmpdir)
        config.adapter_discovery.should be_false
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "ignores unknown keys and wrong types" do
      tmpdir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "config.json"), %({"unknownKey": true, "adapterDiscovery": "not-a-bool"}))
      begin
        config = Chiasmus::Utils::Config.load(tmpdir)
        config.adapter_discovery.should be_false
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe ".save" do
    it "persists config to disk" do
      tmpdir = File.join(Dir.tempdir, "chiasmus-config-spec-#{Random::Secure.hex(8)}")
      begin
        cfg = Chiasmus::Utils::Config::ChiasmusConfig.new(adapter_discovery: true)
        Chiasmus::Utils::Config.save(cfg, tmpdir)
        loaded = Chiasmus::Utils::Config.load(tmpdir)
        loaded.adapter_discovery.should be_true
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe ".chiasmus_home" do
    it "respects CHIASMUS_HOME environment variable" do
      with_env({"CHIASMUS_HOME" => "/tmp/chiasmus-test"}) do
        home = Chiasmus::Utils::Config.chiasmus_home
        home.should eq("/tmp/chiasmus-test")
      end
    end
  end
end
