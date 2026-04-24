require "spec"
require "file_utils"
require "tree_sitter"
require "../../../src/chiasmus/utils/result"
require "../../../src/chiasmus/utils/timeout"
require "../../../src/chiasmus/utils/xdg"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/grammar_operations"
require "../../../src/chiasmus/graph/grammar_manager"
require "../../../src/chiasmus/graph/parser"

class TreeSitter::Config
  def self.test_reset
    @@current = nil
  end
end

class TreeSitter::Repository
  def self.test_reset
    @@language_paths = nil
  end
end

module Chiasmus::Graph::Parser
  def self.test_reset
    service.reset_for_test
  end

  def self.test_seed_cache(language : String, lang : TreeSitter::Language)
    service.seed_cache_for_test(language, lang)
  end

  def self.test_seed_waiters(language : String, count : Int32) : Array(Channel(Chiasmus::Utils::Result(TreeSitter::Language?)))
    service.seed_waiters_for_test(language, count)
  end

  def self.test_notify(language : String, result : Chiasmus::Utils::Result(TreeSitter::Language?))
    service.notify_for_test(language, result)
  end
end

class Chiasmus::Graph::GrammarManager
  def self.test_reset(cache_dir : String? = nil)
    @@mutex.synchronize do
      @@instance = nil
      @@cache_dir = cache_dir
      @@initialized = false
    end
  end
end

private def with_xdg_dirs(cache_home : String, config_home : String, &)
  previous_cache = ENV["XDG_CACHE_HOME"]?
  previous_config = ENV["XDG_CONFIG_HOME"]?

  ENV["XDG_CACHE_HOME"] = cache_home
  ENV["XDG_CONFIG_HOME"] = config_home

  TreeSitter::Config.test_reset
  TreeSitter::Repository.test_reset
  Chiasmus::Graph::LanguageRegistry.clear_cache
  Chiasmus::Graph::GrammarManager.test_reset
  Chiasmus::Graph::Parser.test_reset

  begin
    yield
  ensure
    if previous_cache
      ENV["XDG_CACHE_HOME"] = previous_cache
    else
      ENV.delete("XDG_CACHE_HOME")
    end

    if previous_config
      ENV["XDG_CONFIG_HOME"] = previous_config
    else
      ENV.delete("XDG_CONFIG_HOME")
    end

    TreeSitter::Config.test_reset
    TreeSitter::Repository.test_reset
    Chiasmus::Graph::LanguageRegistry.clear_cache
    Chiasmus::Graph::GrammarManager.test_reset
    Chiasmus::Graph::Parser.test_reset
  end
end

private def stage_python_grammar(cache_home : String)
  source_dir = File.expand_path("../../../vendor/grammars/tree-sitter-python", __DIR__)
  dest_dir = File.join(cache_home, "chiasmus", "grammars", "python")

  Dir.mkdir_p(dest_dir)

  # Copy the compiled library
  ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
  lib_name = "libtree-sitter-python.#{ext}"
  source_lib = File.join(source_dir, lib_name)
  dest_lib = File.join(dest_dir, lib_name)

  if File.exists?(source_lib)
    FileUtils.cp(source_lib, dest_lib)
  else
    # Try to compile it if not already compiled
    Dir.cd(source_dir) do
      `tree-sitter generate 2>/dev/null`
      `tree-sitter build 2>/dev/null`
      # Rename if needed
      if File.exists?("python.#{ext}") && !File.exists?(lib_name)
        File.rename("python.#{ext}", lib_name)
      end
    end

    raise "Failed to compile or find python grammar library" unless File.exists?(source_lib)
    FileUtils.cp(source_lib, dest_lib)
  end
end

private def write_empty_tree_sitter_config(config_home : String)
  config_dir = File.join(config_home, "tree-sitter")
  Dir.mkdir_p(config_dir)
  File.write(File.join(config_dir, "config.json"), %({"parser-directories":[]}))
end

private def build_test_language(name : String) : TreeSitter::Language
  ptr = Pointer(LibTreeSitter::TSLanguage).malloc(1_u64)
  TreeSitter::Language.new(name, ptr)
end

describe "async graph concurrency" do
  it "returns cached async parser languages without deadlocking" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("cached-lang")
    Chiasmus::Graph::Parser.test_seed_cache("cached-lang", lang)

    channel = Chiasmus::Graph::Parser.get_language_async("cached-lang")
    result = Chiasmus::Utils::Timeout.with_timeout_async(100, channel)

    result.should_not be_nil
    result.not_nil!.success?.should be_true
    result.not_nil!.value.should eq(lang)
  end

  it "broadcasts parser results to all pending waiters" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("shared-lang")
    waiters = Chiasmus::Graph::Parser.test_seed_waiters("shared-lang", 2)

    success = Chiasmus::Utils::Result(TreeSitter::Language?).success(lang)
    Chiasmus::Graph::Parser.test_notify("shared-lang", success)

    first = Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[0])
    second = Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[1])
    first.should_not be_nil
    second.should_not be_nil
    first.not_nil!.success?.should be_true
    second.not_nil!.success?.should be_true
    first.not_nil!.value.should eq(lang)
    second.not_nil!.value.should eq(lang)
  end

  it "returns cached parser languages without deadlocking" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("cached-lang-second")
    Chiasmus::Graph::Parser.test_seed_cache("cached-lang-second", lang)

    channel = Chiasmus::Graph::Parser.get_language_async("cached-lang-second")
    result = Chiasmus::Utils::Timeout.with_timeout_async(100, channel)

    result.should_not be_nil
    result.not_nil!.success?.should be_true
    result.not_nil!.value.should eq(lang)
  end

  it "broadcasts parser results to another waiter set" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("shared-lang-second")
    waiters = Chiasmus::Graph::Parser.test_seed_waiters("shared-lang-second", 2)
    success = Chiasmus::Utils::Result(TreeSitter::Language?).success(lang)

    Chiasmus::Graph::Parser.test_notify("shared-lang-second", success)

    first = Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[0])
    second = Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[1])

    first.should_not be_nil
    second.should_not be_nil
    first.not_nil!.success?.should be_true
    second.not_nil!.success?.should be_true
    first.not_nil!.value.should eq(lang)
    second.not_nil!.value.should eq(lang)
  end

  it "treats missing cached grammar as an unavailable grammar, not a timeout failure" do
    cache_dir = File.join(Dir.tempdir, "async-grammar-manager-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(cache_dir)
    Chiasmus::Graph::GrammarManager.test_reset(cache_dir)

    channel = Chiasmus::Graph::GrammarManager.instance.grammar_available_async("definitely-missing-language")
    result = Chiasmus::Utils::Timeout.with_timeout_async(1_000, channel)

    result.should_not be_nil
    result.not_nil!.success?.should be_true
    result.not_nil!.value.should eq(false)
  end

  it "loads an XDG-cached grammar asynchronously without repository parser directories" do
    root_dir = File.join(Dir.tempdir, "async-xdg-parser-spec-#{Random.rand(1_000_000)}")
    cache_home = File.join(root_dir, "cache")
    config_home = File.join(root_dir, "config")

    stage_python_grammar(cache_home)
    write_empty_tree_sitter_config(config_home)

    with_xdg_dirs(cache_home, config_home) do
      channel = Chiasmus::Graph::Parser.get_language_async("python")
      result = Chiasmus::Utils::Timeout.with_timeout_async(5_000, channel)

      result.should_not be_nil
      result.not_nil!.success?.should be_true
      result.not_nil!.value.should_not be_nil
      result.not_nil!.value.not_nil!.name.should eq("python")
    end
  end
end
