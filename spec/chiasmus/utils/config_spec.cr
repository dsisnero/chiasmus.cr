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

describe Chiasmus::Utils::Config do
  describe ".load" do
    it "returns defaults when config.json does not exist" do
      config = Chiasmus::Utils::Config.load("/nonexistent/path")

      config.adapter_discovery.should be_false
    end

    it "reads adapterDiscovery from config.json" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "config.json"), %({"adapterDiscovery":true}))

        config = Chiasmus::Utils::Config.load(dir)

        config.adapter_discovery.should be_true
      end
    end

    it "falls back to defaults for invalid JSON" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "config.json"), "not valid json {{{")

        config = Chiasmus::Utils::Config.load(dir)

        config.adapter_discovery.should be_false
      end
    end

    it "ignores unknown keys and wrong types" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "config.json"), %({"adapterDiscovery":"yes","unknownKey":42}))

        config = Chiasmus::Utils::Config.load(dir)

        config.adapter_discovery.should be_false
      end
    end
  end
end
