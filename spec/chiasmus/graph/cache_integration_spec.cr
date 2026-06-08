require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/cache"

include Chiasmus::Graph

describe "GraphCache integration with extract_graph" do
  it "skips re-extraction for cache-hit files (2nd call is identical)" do
    tmpdir = Dir.tempdir
    cache_dir = File.join(tmpdir, "chiasmus-cache-spec-#{Random::Secure.hex(8)}")
    go_file = File.join(tmpdir, "cache_hit.go")

    begin
      content = <<-GO
        package main
        func main() { helper() }
        func helper() {}
      GO
      File.write(go_file, content)

      sources = [SourceFile.new(path: go_file, content: content)]

      # First extraction (cache miss)
      graph1 = Extractor.extract_graph(sources, cache_dir: cache_dir)
      graph1.defines.size.should eq(2)
      graph1.files.not_nil!.find { |f| f.path == go_file }.should_not be_nil

      # Second extraction (cache hit — should skip tree-sitter parse)
      graph2 = Extractor.extract_graph(sources, cache_dir: cache_dir)
      graph2.defines.size.should eq(2)
      graph2.defines.map(&.name).should eq(graph1.defines.map(&.name))
      graph2.files.not_nil!.size.should eq(graph1.files.not_nil!.size)
    ensure
      File.delete(go_file) if File.exists?(go_file)
      FileUtils.rm_rf(cache_dir) if Dir.exists?(cache_dir)
    end
  end

  it "only re-extracts changed files, reuses cached unchanged files" do
    tmpdir = Dir.tempdir
    cache_dir = File.join(tmpdir, "chiasmus-cache-spec-#{Random::Secure.hex(8)}")
    go_file1 = File.join(tmpdir, "unchanged.go")
    go_file2 = File.join(tmpdir, "changed.go")

    begin
      content1 = "package main\nfunc hello() {}\n"
      content2a = "package main\nfunc world() {}\n"
      content2b = "package main\nfunc world2() {}\n"

      File.write(go_file1, content1)
      File.write(go_file2, content2a)

      # First extraction — both files cached
      sources1 = [SourceFile.new(path: go_file1, content: content1), SourceFile.new(path: go_file2, content: content2a)]
      graph1 = Extractor.extract_graph(sources1, cache_dir: cache_dir)
      graph1.defines.size.should eq(2)
      names1 = graph1.defines.map(&.name).to_set

      # Second extraction — only go_file2 changed
      File.write(go_file2, content2b)
      sources2 = [SourceFile.new(path: go_file1, content: content1), SourceFile.new(path: go_file2, content: content2b)]
      graph2 = Extractor.extract_graph(sources2, cache_dir: cache_dir)

      # The unchanged file's define should still be present (from cache)
      names2 = graph2.defines.map(&.name).to_set
      names2.should contain("hello")
      names2.should contain("world2")
      names2.should_not contain("world")
    ensure
      File.delete(go_file1) if File.exists?(go_file1)
      File.delete(go_file2) if File.exists?(go_file2)
      FileUtils.rm_rf(cache_dir) if Dir.exists?(cache_dir)
    end
  end

  it "produces same graph regardless of cache (deterministic)" do
    tmpdir = Dir.tempdir
    cache_dir = File.join(tmpdir, "chiasmus-cache-spec-#{Random::Secure.hex(8)}")
    go_file = File.join(tmpdir, "deterministic.go")

    begin
      content = <<-GO
        package main
        import "fmt"
        func main() { fmt.Println(helper()) }
        func helper() int { return 42 }
      GO
      File.write(go_file, content)

      sources = [SourceFile.new(path: go_file, content: content)]

      # Without cache
      graph_no_cache = Extractor.extract_graph(sources)
      # With cache (1st call — cache miss → extract + save)
      graph_with_cache = Extractor.extract_graph(sources, cache_dir: cache_dir)
      # With cache (2nd call — cache hit)
      graph_from_cache = Extractor.extract_graph(sources, cache_dir: cache_dir)

      # All three must produce the same define names
      names_no_cache = graph_no_cache.defines.map(&.name).to_set
      names_with_cache = graph_with_cache.defines.map(&.name).to_set
      names_from_cache = graph_from_cache.defines.map(&.name).to_set

      names_with_cache.should eq(names_no_cache)
      names_from_cache.should eq(names_no_cache)

      # FileNodes should match
      graph_with_cache.files.not_nil!.map(&.path).to_set.should eq(
        graph_no_cache.files.not_nil!.map(&.path).to_set
      )
      graph_from_cache.files.not_nil!.map(&.path).to_set.should eq(
        graph_no_cache.files.not_nil!.map(&.path).to_set
      )
    ensure
      File.delete(go_file) if File.exists?(go_file)
      FileUtils.rm_rf(cache_dir) if Dir.exists?(cache_dir)
    end
  end
end
