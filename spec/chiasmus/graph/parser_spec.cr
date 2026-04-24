require "spec"
require "tree_sitter"
require "../../../src/chiasmus/utils/result"
require "../../../src/chiasmus/utils/timeout"
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

class FakeGrammarGateway < Chiasmus::Graph::Parser::GrammarGateway
  property current_path : String?
  property available = true
  getter ensure_calls = 0
  getter init_calls = 0

  def initialize(@current_path : String? = nil, @available : Bool = true, @path_after_ensure : String? = nil)
  end

  def init(cache_dir : String? = nil) : Nil
    @init_calls += 1
  end

  def ensure_grammar_async(language : String, timeout_ms : Int32 = 120_000) : Channel(Chiasmus::Utils::BoolResult)
    @ensure_calls += 1
    @current_path = @path_after_ensure
    channel = Channel(Chiasmus::Utils::BoolResult).new(1)
    channel.send(Chiasmus::Utils::BoolResult.success)
    channel
  end

  def grammar_available_async(language : String) : Channel(Chiasmus::Utils::BoolResult)
    channel = Channel(Chiasmus::Utils::BoolResult).new(1)
    if @available
      channel.send(Chiasmus::Utils::BoolResult.success)
    else
      channel.send(Chiasmus::Utils::BoolResult.new(value: false))
    end
    channel
  end

  def get_grammar_path_async(language : String) : Channel(Chiasmus::Utils::StringResult)
    channel = Channel(Chiasmus::Utils::StringResult).new(1)
    if path = @current_path
      channel.send(Chiasmus::Utils::StringResult.success(path))
    else
      channel.send(Chiasmus::Utils::StringResult.failure("missing", {"language" => language}))
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
    @logical_language ? [@logical_language.not_nil!] : [] of String
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
        result = Chiasmus::Utils::Timeout.with_timeout_async(100, Parser.parse_async("some content", "test.unknown"))

        result.should_not be_nil
        result.not_nil!.failure?.should be_true
        result.not_nil!.error.should eq("Unsupported file extension")
      end

      it "loads a language through injected collaborators" do
        language = build_test_language("python")
        resolver = FakeResolver.new("python", "python")
        environment = FakeParserEnvironment.new
        grammar = FakeGrammarGateway.new("/tmp/python.so")
        loader = FakeLanguageGateway.new
        loader.register("python", "/tmp/python.so", language)
        service = Parser::Service.new(resolver, environment, grammar, loader, FakeTreeBuilder.new)

        result = Chiasmus::Utils::Timeout.with_timeout_async(100, service.get_language_async("python"))

        result.should_not be_nil
        result.not_nil!.success?.should be_true
        result.not_nil!.value.should eq(language)
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

        result = Chiasmus::Utils::Timeout.with_timeout_async(100, service.get_language_async("python"))

        result.should_not be_nil
        result.not_nil!.success?.should be_true
        result.not_nil!.value.should eq(language)
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

        first = Chiasmus::Utils::Timeout.with_timeout_async(100, service.get_language_async("python"))
        second = Chiasmus::Utils::Timeout.with_timeout_async(100, service.get_language_async("python"))

        first.should_not be_nil
        second.should_not be_nil
        first.not_nil!.value.should eq(language)
        second.not_nil!.value.should eq(language)
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
    end
  end
end
