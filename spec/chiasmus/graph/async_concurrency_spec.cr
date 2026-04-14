require "spec"
require "file_utils"
require "tree_sitter"
require "../../../src/chiasmus/utils/result"
require "../../../src/chiasmus/utils/timeout"
require "../../../src/chiasmus/utils/xdg"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/grammar_operations"
require "../../../src/chiasmus/graph/async_grammar_manager"
require "../../../src/chiasmus/graph/async_grammar_manager_v2"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/async_universal_parser"
require "../../../src/chiasmus/graph/async_universal_parser_v2"

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

class Chiasmus::Graph::AsyncUniversalParser
  def self.test_reset
    @@initialized = false
    @@grammar_cache.clear
    @@pending_requests.clear
  end

  def self.test_seed_cache(language : String, lang : TreeSitter::Language)
    @@grammar_cache[language] = lang
  end

  def self.test_seed_waiters(language : String, count : Int32) : Array(Channel(TreeSitter::Language?))
    waiters = Array(Channel(TreeSitter::Language?)).new(count) { Channel(TreeSitter::Language?).new(1) }
    @@pending_requests[language] = waiters
    waiters
  end

  def self.test_notify(language : String, lang : TreeSitter::Language?)
    notify_waiters(language, lang)
  end
end

class Chiasmus::Graph::AsyncUniversalParserV2
  def self.test_reset
    @@initialized = false
    @@grammar_cache.clear
    @@pending_requests.clear
    @@supported_languages_cache = nil
  end

  def self.test_seed_cache(language : String, lang : TreeSitter::Language)
    @@grammar_cache[language] = lang
  end

  def self.test_seed_waiters(language : String, count : Int32) : Array(Channel(Chiasmus::Utils::Result(TreeSitter::Language?)))
    waiters = Array(Channel(Chiasmus::Utils::Result(TreeSitter::Language?))).new(count) do
      Channel(Chiasmus::Utils::Result(TreeSitter::Language?)).new(1)
    end
    @@pending_requests[language] = waiters
    waiters
  end

  def self.test_notify(language : String, result : Chiasmus::Utils::Result(TreeSitter::Language?))
    notify_waiters(language, result)
  end
end

class Chiasmus::Graph::AsyncGrammarManagerV2
  def self.test_reset(cache_dir : String)
    @@cache_dir = cache_dir
    @@initialized = true
  end
end

class Chiasmus::Graph::GrammarManager
  def self.test_reset(cache_dir : String? = nil)
    @@cache_dir = cache_dir
    @@initialized = false
  end
end

private def with_xdg_dirs(cache_home : String, config_home : String, &)
  previous_cache = ENV["XDG_CACHE_HOME"]?
  previous_config = ENV["XDG_CONFIG_HOME"]?

  ENV["XDG_CACHE_HOME"] = cache_home
  ENV["XDG_CONFIG_HOME"] = config_home

  TreeSitter::Config.test_reset
  TreeSitter::Repository.test_reset
  Chiasmus::Graph::GrammarManager.test_reset
  Chiasmus::Graph::AsyncUniversalParser.test_reset
  Chiasmus::Graph::AsyncUniversalParserV2.test_reset

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
    Chiasmus::Graph::GrammarManager.test_reset
    Chiasmus::Graph::AsyncUniversalParser.test_reset
    Chiasmus::Graph::AsyncUniversalParserV2.test_reset
  end
end

private def stage_python_grammar(cache_home : String)
  source_dir = File.expand_path("../../../vendor/grammars/tree-sitter-python", __DIR__)
  dest_dir = File.join(cache_home, "chiasmus", "grammars", "python")

  Dir.mkdir_p(dest_dir)
  Dir.children(source_dir).each do |entry|
    FileUtils.cp_r(File.join(source_dir, entry), File.join(dest_dir, entry))
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
    Chiasmus::Graph::AsyncUniversalParser.test_reset
    lang = build_test_language("cached-lang")
    Chiasmus::Graph::AsyncUniversalParser.test_seed_cache("cached-lang", lang)

    channel = Chiasmus::Graph::AsyncUniversalParser.get_language_async("cached-lang")
    result = Chiasmus::Utils::Timeout.with_timeout_async(100, channel)

    result.should eq(lang)
  end

  it "broadcasts async parser results to all pending waiters" do
    Chiasmus::Graph::AsyncUniversalParser.test_reset
    lang = build_test_language("shared-lang")
    waiters = Chiasmus::Graph::AsyncUniversalParser.test_seed_waiters("shared-lang", 2)

    Chiasmus::Graph::AsyncUniversalParser.test_notify("shared-lang", lang)

    Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[0]).should eq(lang)
    Chiasmus::Utils::Timeout.with_timeout_async(100, waiters[1]).should eq(lang)
  end

  it "returns cached async parser v2 languages without deadlocking" do
    Chiasmus::Graph::AsyncUniversalParserV2.test_reset
    lang = build_test_language("cached-lang-v2")
    Chiasmus::Graph::AsyncUniversalParserV2.test_seed_cache("cached-lang-v2", lang)

    channel = Chiasmus::Graph::AsyncUniversalParserV2.get_language_async("cached-lang-v2")
    result = Chiasmus::Utils::Timeout.with_timeout_async(100, channel)

    result.should_not be_nil
    result.not_nil!.success?.should be_true
    result.not_nil!.value.should eq(lang)
  end

  it "broadcasts async parser v2 results to all pending waiters" do
    Chiasmus::Graph::AsyncUniversalParserV2.test_reset
    lang = build_test_language("shared-lang-v2")
    waiters = Chiasmus::Graph::AsyncUniversalParserV2.test_seed_waiters("shared-lang-v2", 2)
    success = Chiasmus::Utils::Result(TreeSitter::Language?).success(lang)

    Chiasmus::Graph::AsyncUniversalParserV2.test_notify("shared-lang-v2", success)

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
    cache_dir = File.join(Dir.tempdir, "async-grammar-manager-v2-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(cache_dir)
    Chiasmus::Graph::AsyncGrammarManagerV2.test_reset(cache_dir)

    channel = Chiasmus::Graph::AsyncGrammarManagerV2.grammar_available_async("definitely-missing-language")
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
      channel = Chiasmus::Graph::AsyncUniversalParserV2.get_language_async("python")
      result = Chiasmus::Utils::Timeout.with_timeout_async(5_000, channel)

      result.should_not be_nil
      result.not_nil!.success?.should be_true
      result.not_nil!.value.should_not be_nil
      result.not_nil!.value.not_nil!.name.should eq("python")
    end
  end
end
