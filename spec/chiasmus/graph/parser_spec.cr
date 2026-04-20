require "spec"
require "file_utils"
require "tree_sitter"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/utils/result"
require "../../../src/chiasmus/utils/timeout"
require "../../../src/chiasmus/utils/xdg"
require "../../../src/chiasmus/graph/grammar_operations"
require "../../../src/chiasmus/graph/grammar_manager"
require "../../../src/chiasmus/graph/universal_parser"
require "../../../src/chiasmus/graph/async_universal_parser_v2"
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

class Chiasmus::Graph::GrammarManager
  def self.test_reset(cache_dir : String? = nil)
    @@mutex.synchronize do
      @@instance = nil
      @@cache_dir = cache_dir
      @@initialized = false
    end
  end
end

class Chiasmus::Graph::UniversalParser
  def self.test_reset
    @@initialized = false
    @@grammar_cache.clear
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
  Chiasmus::Graph::UniversalParser.test_reset

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
    Chiasmus::Graph::UniversalParser.test_reset
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

module Chiasmus
  module Graph
    describe Parser do
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

      it "returns null for unsupported extension" do
        tree = Parser.parse_source("some content", "test.unknown")
        tree.should be_nil
      end

      it "parses Crystal source when grammar is available and otherwise returns nil cleanly" do
        tree = Parser.parse_source("def hello\nend", "test.cr")

        if tree.nil?
          tree.should be_nil
        else
          root = tree.root_node
          root.should_not be_nil
        end
      end

      it "parses from an XDG-cached grammar even when repository config has no parser directories" do
        root_dir = File.join(Dir.tempdir, "xdg-parser-spec-#{Random.rand(1_000_000)}")
        cache_home = File.join(root_dir, "cache")
        config_home = File.join(root_dir, "config")

        stage_python_grammar(cache_home)
        write_empty_tree_sitter_config(config_home)

        with_xdg_dirs(cache_home, config_home) do
          ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
          GrammarManager.ensure_grammar("python").should be_true
          GrammarManager.get_grammar_path("python").should eq(
            File.join(cache_home, "chiasmus", "grammars", "python", "libtree-sitter-python.#{ext}")
          )

          parser_tree = Parser.parse_source("def hello():\n    return 1\n", "test.py")
          parser_tree.should_not be_nil
          parser_tree.not_nil!.root_node.type.should eq("module")

          tree = UniversalParser.parse("def hello():\n    return 1\n", "test.py")

          tree.should_not be_nil
          tree.not_nil!.root_node.type.should eq("module")
        end
      end

      it "does not raise when the tree-sitter config file is missing" do
        root_dir = File.join(Dir.tempdir, "xdg-missing-config-spec-#{Random.rand(1_000_000)}")
        cache_home = File.join(root_dir, "cache")
        config_home = File.join(root_dir, "config")

        with_xdg_dirs(cache_home, config_home) do
          ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
          path = GrammarManager.get_grammar_path("go")
          (path.nil? || path.ends_with?("libtree-sitter-go.#{ext}")).should be_true
        end
      end
    end
  end
end
