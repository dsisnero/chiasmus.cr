require "spec"
require "file_utils"
require "tree_sitter"
require "tree-sitter-manager"
require "../../support/grammar_manager_test_support"
require "../../../src/chiasmus/graph/types"
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

  def self.test_seed_waiters(language : String, count : Int32) : Array(Channel(TreeSitterManager::Result(TreeSitter::Language?)))
    service.seed_waiters_for_test(language, count)
  end

  def self.test_notify(language : String, result : TreeSitterManager::Result(TreeSitter::Language?))
    service.notify_for_test(language, result)
  end
end

class TreeSitterManager::GrammarManager
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
  TreeSitterManager::LanguageRegistry.clear_cache
  TreeSitterManager::GrammarManager.test_reset
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
    TreeSitterManager::LanguageRegistry.clear_cache
    TreeSitterManager::GrammarManager.test_reset
    Chiasmus::Graph::Parser.test_reset
  end
end

private def python_grammar_source_dir : String
  if env_dir = ENV["CHIASMUS_GRAMMAR_DIR"]?
    candidate = File.join(env_dir, "tree-sitter-python")
    return candidate if Dir.exists?(candidate)
  end

  File.expand_path("../../../grammars/tree-sitter-python", __DIR__)
end

private def python_grammar_source_lib : String
  ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
  File.join(python_grammar_source_dir, "libtree-sitter-python.#{ext}")
end

private def python_grammar_source_available? : Bool
  File.exists?(python_grammar_source_lib)
end

private def stage_python_grammar(cache_home : String) : Bool
  source_dir = python_grammar_source_dir
  dest_dir = File.join(cache_home, "tree-sitter-manager", "grammars", "python")

  Dir.mkdir_p(dest_dir)

  # Copy the compiled library
  ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
  lib_name = "libtree-sitter-python.#{ext}"
  source_lib = python_grammar_source_lib
  dest_lib = File.join(dest_dir, lib_name)

  if File.exists?(source_lib)
    FileUtils.cp(source_lib, dest_lib)
    true
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

    return false unless File.exists?(source_lib)
    FileUtils.cp(source_lib, dest_lib)
    true
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
    result = TreeSitterManager::Timeout.with_timeout_async(100, channel)

    result.should_not be_nil
    raise "expected non-nil result" if result.nil?
    result.success?.should be_true
    result.value.should eq(lang)
  end

  it "broadcasts parser results to all pending waiters" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("shared-lang")
    waiters = Chiasmus::Graph::Parser.test_seed_waiters("shared-lang", 2)

    success = TreeSitterManager::Result(TreeSitter::Language?).success(lang)
    Chiasmus::Graph::Parser.test_notify("shared-lang", success)

    first = TreeSitterManager::Timeout.with_timeout_async(100, waiters[0])
    second = TreeSitterManager::Timeout.with_timeout_async(100, waiters[1])
    first.should_not be_nil
    second.should_not be_nil
    raise "expected non-nil first" if first.nil?
    first.success?.should be_true
    raise "expected non-nil second" if second.nil?
    second.success?.should be_true
    first.value.should eq(lang)
    second.value.should eq(lang)
  end

  it "returns cached parser languages without deadlocking" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("cached-lang-second")
    Chiasmus::Graph::Parser.test_seed_cache("cached-lang-second", lang)

    channel = Chiasmus::Graph::Parser.get_language_async("cached-lang-second")
    result = TreeSitterManager::Timeout.with_timeout_async(100, channel)

    result.should_not be_nil
    raise "expected non-nil result" if result.nil?
    result.success?.should be_true
    result.value.should eq(lang)
  end

  it "broadcasts parser results to another waiter set" do
    Chiasmus::Graph::Parser.test_reset
    lang = build_test_language("shared-lang-second")
    waiters = Chiasmus::Graph::Parser.test_seed_waiters("shared-lang-second", 2)
    success = TreeSitterManager::Result(TreeSitter::Language?).success(lang)

    Chiasmus::Graph::Parser.test_notify("shared-lang-second", success)

    first = TreeSitterManager::Timeout.with_timeout_async(100, waiters[0])
    second = TreeSitterManager::Timeout.with_timeout_async(100, waiters[1])

    first.should_not be_nil
    second.should_not be_nil
    raise "expected non-nil first" if first.nil?
    first.success?.should be_true
    raise "expected non-nil second" if second.nil?
    second.success?.should be_true
    first.value.should eq(lang)
    second.value.should eq(lang)
  end

  it "treats missing cached grammar as an unavailable grammar, not a timeout failure" do
    cache_dir = File.join(Dir.tempdir, "async-grammar-manager-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(cache_dir)
    TreeSitterManager::GrammarManager.test_reset(cache_dir)

    channel = TreeSitterManager::GrammarManager.instance.grammar_available_async("definitely-missing-language")
    result = TreeSitterManager::Timeout.with_timeout_async(1_000, channel)

    result.should_not be_nil
    raise "expected non-nil result" if result.nil?
    result.success?.should be_true
    result.value.should eq(false)
  end

  it "coalesces concurrent ensure_grammar_async calls for the same language" do
    cache_dir = File.join(Dir.tempdir, "async-grammar-manager-coalesce-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(cache_dir)
    TreeSitterManager::GrammarManager.test_reset(cache_dir)

    manager = TreeSitterManager::GrammarManager.instance
    install_calls = Atomic(Int32).new(0)
    release_install = Channel(Bool).new(1)

    manager.set_install_hook_for_test do |_language|
      install_calls.add(1)
      release_install.receive
      TreeSitterManager::BoolResult.success
    end

    begin
      first = manager.ensure_grammar_async("coalesced-language", 1_000)
      second = manager.ensure_grammar_async("coalesced-language", 1_000)

      ready = TreeSitterManager::Timeout.with_timeout(1_000) do
        until install_calls.get == 1
          Fiber.yield
        end
        true
      end

      ready.should eq(true)
      release_install.send(true)

      first_result = TreeSitterManager::Timeout.with_timeout_async(500, first)
      second_result = TreeSitterManager::Timeout.with_timeout_async(500, second)

      first_result.should_not be_nil
      second_result.should_not be_nil
      raise "expected non-nil first result" if first_result.nil?
      raise "expected non-nil second result" if second_result.nil?
      first_result.success?.should be_true
      second_result.success?.should be_true
      install_calls.get.should eq(1)
    ensure
      manager.clear_install_hook_for_test
    end
  end

  if python_grammar_source_available?
    it "loads an XDG-cached grammar asynchronously without repository parser directories" do
      root_dir = File.join(Dir.tempdir, "async-xdg-parser-spec-#{Random.rand(1_000_000)}")
      cache_home = File.join(root_dir, "cache")
      config_home = File.join(root_dir, "config")

      stage_python_grammar(cache_home).should be_true
      write_empty_tree_sitter_config(config_home)

      with_xdg_dirs(cache_home, config_home) do
        TreeSitterManager::XDG.grammar_cache_dir.should eq(
          File.join(cache_home, "tree-sitter-manager", "grammars")
        )
        channel = Chiasmus::Graph::Parser.get_language_async("python")
        result = TreeSitterManager::Timeout.with_timeout_async(5_000, channel)

        result.should_not be_nil
        raise "expected non-nil result" if result.nil?
        result.success?.should be_true
        result.value.should_not be_nil
        value = result.value
        raise "expected non-nil value" if value.nil?
        value.name.should eq("python")
      end
    end
  else
    pending "loads an XDG-cached grammar asynchronously without repository parser directories (python grammar library not available for XDG cache staging)"
  end
end
