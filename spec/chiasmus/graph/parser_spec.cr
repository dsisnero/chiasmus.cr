require "spec"
require "tree_sitter"
require "tree-sitter-manager"
require "../../../src/chiasmus/graph/parser"

private def build_test_language(name : String) : TreeSitter::Language
  ptr = Pointer(LibTreeSitter::TSLanguage).malloc(1_u64)
  TreeSitter::Language.new(name, ptr)
end

class FakeParserEnvironment < Chiasmus::Graph::Parser::Environment
  getter ensure_calls = 0

  def ensure_tree_sitter_config : Nil
    @ensure_calls += 1
  end
end

class SleepingParserEnvironment < Chiasmus::Graph::Parser::Environment
  getter ensure_calls = 0

  def initialize(@sleep_for = 50.milliseconds)
  end

  def ensure_tree_sitter_config : Nil
    @ensure_calls += 1
    sleep(@sleep_for)
  end
end

class FakeGrammarGateway < Chiasmus::Graph::Parser::GrammarGateway
  property current_path : String?
  getter? available : Bool
  getter ensure_calls = 0
  getter init_calls = 0

  def initialize(@current_path : String? = nil, @available : Bool = true, @path_after_ensure : String? = nil)
  end

  def init(cache_dir : String? = nil) : Nil
    @init_calls += 1
  end

  def ensure_grammar_async(language : String, timeout_ms : Int32 = 120_000) : Channel(TreeSitterManager::BoolResult)
    @ensure_calls += 1
    @current_path = @path_after_ensure
    channel = Channel(TreeSitterManager::BoolResult).new(1)
    channel.send(TreeSitterManager::BoolResult.success)
    channel
  end

  def grammar_available_async(language : String) : Channel(TreeSitterManager::BoolResult)
    channel = Channel(TreeSitterManager::BoolResult).new(1)
    if @available
      channel.send(TreeSitterManager::BoolResult.success)
    else
      channel.send(TreeSitterManager::BoolResult.new(value: false))
    end
    channel
  end

  def get_grammar_path_async(language : String) : Channel(TreeSitterManager::StringResult)
    channel = Channel(TreeSitterManager::StringResult).new(1)
    if path = @current_path
      channel.send(TreeSitterManager::StringResult.success(path))
    else
      channel.send(TreeSitterManager::StringResult.failure("missing", {"language" => language}))
    end
    channel
  end

  def ensure_grammar(language : String, timeout_ms : Int32 = 120_000) : Bool
    @ensure_calls += 1
    @current_path = @path_after_ensure
    true
  end

  def get_grammar_path(language : String) : String?
    @current_path
  end
end

class FakeLanguageGateway < Chiasmus::Graph::Parser::LanguageGateway
  property repository_names : Array(String)
  getter loads = [] of {String, String}

  def initialize(@repository_names = [] of String)
    @languages = {} of String => TreeSitter::Language
  end

  def register(language : String, path : String, value : TreeSitter::Language) : Nil
    @languages["#{language}:#{path}"] = value
  end

  def repository_language_names : Array(String)
    @repository_names
  end

  def load_language_from_grammar_path(language : String, grammar_path : String) : TreeSitter::Language?
    @loads << {language, grammar_path}
    @languages["#{language}:#{grammar_path}"]?
  end
end

class FakeTreeBuilder < Chiasmus::Graph::Parser::TreeBuilder
  getter calls = [] of {String, String}

  def initialize(@raise_error = false)
  end

  def build(lang : TreeSitter::Language, content : String) : TreeSitter::Tree?
    @calls << {lang.name, content}
    raise "boom" if @raise_error
    nil
  end
end

class FakeResolver < Chiasmus::Graph::Parser::LanguageResolver
  def initialize(
    @logical_language : String? = nil,
    @grammar_language : String? = nil,
    @extensions = [".fake"] of String,
    @known = true,
  )
  end

  def language_for_file(file_path : String) : String?
    @logical_language
  end

  def grammar_language_for_file(file_path : String) : String?
    @grammar_language
  end

  def supported_extensions : Array(String)
    @extensions
  end

  def supported_languages : Array(String)
    if lang = @logical_language
      [lang]
    else
      [] of String
    end
  end

  def known_language?(language : String) : Bool
    @known
  end
end

class RecordingParserService < Chiasmus::Graph::Parser::Service
  getter extension_calls = 0

  def initialize
    super(
      FakeResolver.new,
      FakeParserEnvironment.new,
      FakeGrammarGateway.new,
      FakeLanguageGateway.new,
      FakeTreeBuilder.new
    )
  end

  def supported_extensions : Array(String)
    @extension_calls += 1
    [".custom"]
  end
end

module Chiasmus
  module Graph
    describe Parser do
      after_each do
        Parser.reset_service
      end

      it "maps extensions to languages correctly" do
        Parser.get_language_for_file("foo.ts").should eq "typescript"
        Parser.get_language_for_file("foo.tsx").should eq "tsx"
        Parser.get_language_for_file("foo.js").should eq "javascript"
        Parser.get_language_for_file("foo.mjs").should eq "javascript"
        Parser.get_language_for_file("foo.py").should eq "python"
        Parser.get_language_for_file("foo.go").should eq "go"
        Parser.get_language_for_file("foo.clj").should eq "clojure"
        Parser.get_language_for_file("foo.cr").should eq "crystal"
        Parser.get_language_for_file("foo.unknown").should be_nil
      end

      it "lists supported extensions" do
        exts = Parser.supported_extensions
        exts.should contain ".ts"
        exts.should contain ".js"
        exts.should contain ".tsx"
        exts.should contain ".py"
        exts.should contain ".go"
        exts.should contain ".clj"
        exts.should contain ".cr"
      end

      it "returns nil for unsupported files through the synchronous parser API" do
        Parser.parse_source("some content", "test.unknown").should be_nil
      end

      it "returns a failure result for unsupported files through the async parser API" do
        result = TreeSitterManager::Timeout.with_timeout_async(100, Parser.parse_async("some content", "test.unknown"))

        result.should_not be_nil
        res = result || raise "Expected result"
        res.failure?.should be_true
        res.error.should eq("Unsupported file extension")
      end

      it "loads a language through injected collaborators" do
        language = build_test_language("python")
        resolver = FakeResolver.new("python", "python")
        environment = FakeParserEnvironment.new
        grammar = FakeGrammarGateway.new("/tmp/python.so")
        loader = FakeLanguageGateway.new
        loader.register("python", "/tmp/python.so", language)
        service = Parser::Service.new(resolver, environment, grammar, loader, FakeTreeBuilder.new)

        result = TreeSitterManager::Timeout.with_timeout_async(100, service.get_language_async("python"))

        result.should_not be_nil
        res = result || raise "Expected result"
        res.success?.should be_true
        res.value.should eq(language)
        environment.ensure_calls.should eq(1)
        grammar.init_calls.should eq(1)
        grammar.ensure_calls.should eq(0)
        loader.loads.should eq([{"python", "/tmp/python.so"}])
      end

      it "ensures the grammar when the initial lookup misses" do
        language = build_test_language("python")
        resolver = FakeResolver.new("python", "python")
        grammar = FakeGrammarGateway.new(nil, true, "/tmp/python.so")
        loader = FakeLanguageGateway.new
        loader.register("python", "/tmp/python.so", language)
        service = Parser::Service.new(
          resolver,
          FakeParserEnvironment.new,
          grammar,
          loader,
          FakeTreeBuilder.new
        )

        result = TreeSitterManager::Timeout.with_timeout_async(100, service.get_language_async("python"))
        result.should_not be_nil
        res = result || raise "Expected result"
        res.success?.should be_true
        res.value.should eq(language)
        grammar.ensure_calls.should eq(1)
        loader.loads.should eq([{"python", "/tmp/python.so"}])
      end

      it "reuses the cached language after the first load" do
        language = build_test_language("python")
        resolver = FakeResolver.new("python", "python")
        grammar = FakeGrammarGateway.new("/tmp/python.so")
        loader = FakeLanguageGateway.new
        loader.register("python", "/tmp/python.so", language)
        service = Parser::Service.new(
          resolver,
          FakeParserEnvironment.new,
          grammar,
          loader,
          FakeTreeBuilder.new
        )

        first = TreeSitterManager::Timeout.with_timeout_async(100, service.get_language_async("python"))
        second = TreeSitterManager::Timeout.with_timeout_async(100, service.get_language_async("python"))

        first.should_not be_nil
        second.should_not be_nil
        first_res = first || raise "Expected first"
        second_res = second || raise "Expected second"
        first_res.value.should eq(language)
        second_res.value.should eq(language)
        loader.loads.should eq([{"python", "/tmp/python.so"}])
      end

      it "computes supported languages from repository and grammar availability" do
        resolver = FakeResolver.new(
          "python",
          "python",
          [".fake"] of String,
          true
        )
        grammar = FakeGrammarGateway.new(nil, false)
        loader = FakeLanguageGateway.new(["python"])
        service = Parser::Service.new(
          resolver,
          FakeParserEnvironment.new,
          grammar,
          loader,
          FakeTreeBuilder.new
        )

        service.supported_languages.should eq(["python"])
        service.supports_language?("python").should be_false
      end

      it "lets the parser facade swap in a test service" do
        recording = RecordingParserService.new
        previous = Parser.service
        Parser.service = recording

        begin
          Parser.supported_extensions.should eq([".custom"])
        ensure
          Parser.service = previous
        end

        recording.extension_calls.should eq(1)
      end

      it "initializes the parser service once under concurrent callers" do
        language = build_test_language("python")
        resolver = FakeResolver.new("python", "python")
        environment = SleepingParserEnvironment.new
        grammar = FakeGrammarGateway.new("/tmp/python.so")
        loader = FakeLanguageGateway.new
        loader.register("python", "/tmp/python.so", language)
        service = Parser::Service.new(
          resolver,
          environment,
          grammar,
          loader,
          FakeTreeBuilder.new
        )

        start = Channel(Nil).new(2)
        done = Channel(TreeSitterManager::Result(TreeSitter::Language?)).new(2)

        2.times do
          spawn do
            start.receive
            result = TreeSitterManager::Timeout.with_timeout_async(500, service.get_language_async("python"))
            done.send(result || raise "expected language result")
          end
        end

        2.times { start.send(nil) }
        2.times do
          result = done.receive
          result.success?.should be_true
          result.value.should eq(language)
        end

        environment.ensure_calls.should eq(1)
        grammar.init_calls.should eq(1)
      end
    end
  end
end
