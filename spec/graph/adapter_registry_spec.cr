require "../spec_helper"

# Test adapter that implements the LanguageAdapter interface
class TestLanguageAdapter < Chiasmus::Graph::LanguageAdapter
  def language : String
    "testlang"
  end

  def extensions : Array(String)
    [".tl", ".test"]
  end

  def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Chiasmus::Graph::CodeGraph
    Chiasmus::Graph::CodeGraph.new
  end

  def grammar_language : String
    "testlang-grammar"
  end

  def search_paths : Array(String)?
    ["/tmp/test-search"]
  end
end

class TestAdapterFactory < Chiasmus::Graph::AdapterFactory
  @built_language : String = "testlang"

  def build(descriptor : Chiasmus::Graph::AdapterDescriptor) : Chiasmus::Graph::LanguageAdapter?
    @built_language = descriptor.language
    DescriptorAdapter.new(descriptor)
  end
end

class DescriptorAdapter < Chiasmus::Graph::LanguageAdapter
  def initialize(@descriptor : Chiasmus::Graph::AdapterDescriptor)
  end

  def language : String
    @descriptor.language
  end

  def extensions : Array(String)
    @descriptor.extensions
  end

  def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Chiasmus::Graph::CodeGraph
    Chiasmus::Graph::CodeGraph.new
  end

  def grammar_language : String
    @descriptor.grammar_language
  end

  def search_paths : Array(String)?
    @descriptor.search_paths
  end
end

describe Chiasmus::Graph::AdapterRegistry do
  before_each do
    Chiasmus::Graph::AdapterRegistry.clear_adapters
    Chiasmus::Graph::AdapterRegistry.clear_adapter_factories
  end

  describe ".register_adapter" do
    it "registers an adapter and makes it retrievable by language" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)

      retrieved = Chiasmus::Graph::AdapterRegistry.get_adapter("testlang")
      retrieved.should_not be_nil
      retrieved.not_nil!.language.should eq("testlang")
    end

    it "registers extensions without leading dot" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)

      ext = Chiasmus::Graph::AdapterRegistry.language_for_ext("tl")
      ext.should eq("testlang")
    end

    it "normalizes extensions with leading dot" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)

      ext = Chiasmus::Graph::AdapterRegistry.language_for_ext(".tl")
      ext.should eq("testlang")
    end

    it "resolves adapter by file extension" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)

      resolved = Chiasmus::Graph::AdapterRegistry.get_adapter_for_ext(".test")
      resolved.should_not be_nil
      resolved.not_nil!.language.should eq("testlang")
    end

    it "returns nil for unregistered extension" do
      result = Chiasmus::Graph::AdapterRegistry.language_for_ext(".unknown")
      result.should be_nil
    end

    it "returns nil for unregistered language" do
      result = Chiasmus::Graph::AdapterRegistry.get_adapter("nonexistent")
      result.should be_nil
    end
  end

  describe ".register_adapter_factory" do
    it "registers a factory by entrypoint name" do
      factory = TestAdapterFactory.new
      Chiasmus::Graph::AdapterRegistry.register_adapter_factory("test.entrypoint", factory)
      # Factory registration is verified via manifest discovery (next test)
    end
  end

  describe ".clear_adapters" do
    it "removes all registered adapters" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)
      Chiasmus::Graph::AdapterRegistry.get_adapter("testlang").should_not be_nil

      Chiasmus::Graph::AdapterRegistry.clear_adapters
      Chiasmus::Graph::AdapterRegistry.get_adapter("testlang").should be_nil
    end

    it "clears extension map" do
      adapter = TestLanguageAdapter.new
      Chiasmus::Graph::AdapterRegistry.register_adapter(adapter)
      Chiasmus::Graph::AdapterRegistry.language_for_ext("tl").should_not be_nil

      Chiasmus::Graph::AdapterRegistry.clear_adapters
      Chiasmus::Graph::AdapterRegistry.language_for_ext("tl").should be_nil
    end
  end

  describe ".discover_adapters" do
    it "discovers adapters from a manifest JSON file" do
      tmpdir = File.join(Dir.tempdir, "adapter-registry-spec-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      manifest_path = File.join(tmpdir, "chiasmus.adapters.json")
      manifest = {
        "adapters" => [
          {
            "language"    => "mylang",
            "extensions"  => [".ml", ".mylang"],
            "entrypoint"  => "test.entrypoint",
            "grammar_language" => "mylang",
          },
        ],
      }
      File.write(manifest_path, manifest.to_json)

      begin
        factory = TestAdapterFactory.new
        Chiasmus::Graph::AdapterRegistry.register_adapter_factory("test.entrypoint", factory)

        Chiasmus::Graph::AdapterRegistry.discover_adapters([manifest_path])
        Chiasmus::Graph::AdapterRegistry.get_adapter("mylang").should_not be_nil
      ensure
        Chiasmus::Graph::AdapterRegistry.clear_adapters
        Chiasmus::Graph::AdapterRegistry.clear_adapter_factories
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "is idempotent — only runs once" do
      tmpdir = File.join(Dir.tempdir, "adapter-idem-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      manifest_path = File.join(tmpdir, "chiasmus.adapters.json")
      manifest = {
        "adapters" => [
          {
            "language"   => "idemlang",
            "extensions" => [".idm"],
            "entrypoint" => "test.entrypoint",
          },
        ],
      }
      File.write(manifest_path, manifest.to_json)

      begin
        factory = TestAdapterFactory.new
        Chiasmus::Graph::AdapterRegistry.register_adapter_factory("test.entrypoint", factory)
        Chiasmus::Graph::AdapterRegistry.clear_adapters

        Chiasmus::Graph::AdapterRegistry.discover_adapters([manifest_path])
        first_size = Chiasmus::Graph::AdapterRegistry.adapter_extensions.size

        Chiasmus::Graph::AdapterRegistry.discover_adapters([manifest_path])
        Chiasmus::Graph::AdapterRegistry.adapter_extensions.size.should eq(first_size)
      ensure
        Chiasmus::Graph::AdapterRegistry.clear_adapters
        Chiasmus::Graph::AdapterRegistry.clear_adapter_factories
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "skips invalid descriptors without crashing" do
      tmpdir = File.join(Dir.tempdir, "adapter-invalid-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      manifest_path = File.join(tmpdir, "chiasmus.adapters.json")
      manifest = {
        "adapters" => [
          {"language" => "badlang"}, # missing extensions and entrypoint
        ],
      }
      File.write(manifest_path, manifest.to_json)

      begin
        Chiasmus::Graph::AdapterRegistry.discover_adapters([manifest_path])
        Chiasmus::Graph::AdapterRegistry.get_adapter("badlang").should be_nil
      ensure
        Chiasmus::Graph::AdapterRegistry.clear_adapters
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "skips descriptors with missing factory" do
      tmpdir = File.join(Dir.tempdir, "adapter-nofactory-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      manifest_path = File.join(tmpdir, "chiasmus.adapters.json")
      manifest = {
        "adapters" => [
          {
            "language"    => "nofactory",
            "extensions"  => [".nf"],
            "entrypoint"  => "nonexistent.factory",
          },
        ],
      }
      File.write(manifest_path, manifest.to_json)

      begin
        Chiasmus::Graph::AdapterRegistry.discover_adapters([manifest_path])
        Chiasmus::Graph::AdapterRegistry.get_adapter("nofactory").should be_nil
      ensure
        Chiasmus::Graph::AdapterRegistry.clear_adapters
      end
    end
  end
end
