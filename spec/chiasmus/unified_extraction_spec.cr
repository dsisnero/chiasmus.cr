require "spec"
require "../../src/chiasmus/graph/extractor"

class CountingJavaParser
  getter parse_count = 0

  def language_for_file(file_path : String) : String?
    Chiasmus::Graph::Parser.language_for_file(file_path)
  end

  def parse_source(content : String, file_path : String) : TreeSitter::Tree?
    @parse_count += 1
    Chiasmus::Graph::Parser.parse_source(content, file_path)
  end
end

describe Chiasmus::Graph::Extractor do
  it "runs graph and discovery extraction from one Java parse tree" do
    source = <<-JAVA
      class Greeter {
        void greet() {}
      }
      JAVA
    file = Chiasmus::Graph::SourceFile.new("Greeter.java", source)
    parser = CountingJavaParser.new

    result = Chiasmus::Graph::Extractor.extract_with_discovery(file, "java", parser)
    combined = result || raise "expected combined extraction result"

    parser.parse_count.should eq(1)
    combined.graph.defines.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("greet")
  end

  it "reuses a combined extraction and invalidates it on content edits" do
    dir = File.join(Dir.tempdir, "chiasmus-unified-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "Greeter.java")
      cache_dir = File.join(dir, "cache")
      parser = CountingJavaParser.new
      first_source = "class Greeter { void greet() {} }"
      second_source = "class Greeter { void greet() {} void wave() {} }"

      first = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, first_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      warm = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, first_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )
      edited = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, second_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )

      parser.parse_count.should eq(2)
      warm.should eq(first)
      edited_result = edited || raise "expected edited extraction"
      edited_result.discovery.items.map(&.name).should contain("wave")
      edited_result.graph.defines.map(&.name).should contain("wave")
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "coalesces concurrent requests for one cached file" do
    dir = File.join(Dir.tempdir, "chiasmus-unified-concurrent-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      file = Chiasmus::Graph::SourceFile.new(File.join(dir, "Greeter.java"), "class Greeter { void greet() {} }")
      parser = CountingJavaParser.new
      results = Channel(Chiasmus::Graph::Extractor::UnifiedFileResult?).new(2)
      2.times do
        spawn do
          results.send(Chiasmus::Graph::Extractor.extract_with_discovery(file, "java", parser, cache_dir: File.join(dir, "cache"), repo_key: "single-flight"))
        end
      end
      first = results.receive
      second = results.receive
      first.should eq(second)
      parser.parse_count.should eq(1)
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
