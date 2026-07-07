require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/cache"

include Chiasmus::Graph

private def run_git!(repo : String, args : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("git", args, chdir: repo, output: output, error: error)
  raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  output.to_s
end

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
      files = graph1.files
      raise "expected non-nil files" if files.nil?
      files.find { |file_node| file_node.path == go_file }.should_not be_nil

      # Second extraction (cache hit — should skip tree-sitter parse)
      graph2 = Extractor.extract_graph(sources, cache_dir: cache_dir)
      graph2.defines.size.should eq(2)
      graph2.defines.map(&.name).should eq(graph1.defines.map(&.name))
      files2 = graph2.files
      raise "expected non-nil files" if files2.nil?
      files2.size.should eq(files.size)
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
      files_wc = graph_with_cache.files
      raise "expected non-nil files" if files_wc.nil?
      files_nc = graph_no_cache.files
      raise "expected non-nil files" if files_nc.nil?
      files_fc = graph_from_cache.files
      raise "expected non-nil files" if files_fc.nil?
      files_wc.map(&.path).to_set.should eq(
        files_nc.map(&.path).to_set
      )
      files_fc.map(&.path).to_set.should eq(
        files_nc.map(&.path).to_set
      )
    ensure
      File.delete(go_file) if File.exists?(go_file)
      FileUtils.rm_rf(cache_dir) if Dir.exists?(cache_dir)
    end
  end

  it "reuses tracked clean file cache entries across worktrees of the same repo" do
    repo_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-#{Random::Secure.hex(8)}")
    worktree_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-wt-#{Random::Secure.hex(8)}")
    cache_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-cache-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(repo_dir)

    begin
      run_git!(repo_dir, ["init", "-b", "main"])
      run_git!(repo_dir, ["config", "user.email", "spec@example.com"])
      run_git!(repo_dir, ["config", "user.name", "Spec User"])

      source_rel = File.join("src", "demo.cr")
      source_path = File.join(repo_dir, source_rel)
      Dir.mkdir_p(File.dirname(source_path))
      source = "module Demo\n  def self.run\n  end\nend\n"
      File.write(source_path, source)
      run_git!(repo_dir, ["add", source_rel])
      run_git!(repo_dir, ["commit", "-m", "initial cache integration fixture"])
      run_git!(repo_dir, ["worktree", "add", worktree_dir, "-b", "cache-spec-worktree"])

      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: source_rel, name: "run", kind: SymbolKind::Function, line: 2)],
      )

      GraphCache.save_file_cache([
        {path: source_path, content: source, graph: graph},
      ], cache_dir, repo_key: GraphCache.default_repo_key(repo_dir))

      worktree_source = File.join(worktree_dir, source_rel)
      result = GraphCache.check_file_cache([
        {path: worktree_source, content: File.read(worktree_source)},
      ], cache_dir, repo_key: GraphCache.default_repo_key(worktree_dir))

      result[:misses].should be_empty
      result[:hits].size.should eq(1)
      result[:hits].first[:graph].defines.first.name.should eq("run")
    ensure
      FileUtils.rm_rf(worktree_dir)
      FileUtils.rm_rf(repo_dir)
      FileUtils.rm_rf(cache_dir)
    end
  end

  it "falls back to content hashing for modified worktree files" do
    repo_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-mod-#{Random::Secure.hex(8)}")
    worktree_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-mod-wt-#{Random::Secure.hex(8)}")
    cache_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-mod-cache-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(repo_dir)

    begin
      run_git!(repo_dir, ["init", "-b", "main"])
      run_git!(repo_dir, ["config", "user.email", "spec@example.com"])
      run_git!(repo_dir, ["config", "user.name", "Spec User"])

      source_rel = File.join("src", "demo.cr")
      source_path = File.join(repo_dir, source_rel)
      Dir.mkdir_p(File.dirname(source_path))
      source = "module Demo\n  def self.run\n  end\nend\n"
      File.write(source_path, source)
      run_git!(repo_dir, ["add", source_rel])
      run_git!(repo_dir, ["commit", "-m", "initial modified cache fixture"])
      run_git!(repo_dir, ["worktree", "add", worktree_dir, "-b", "cache-spec-mod-worktree"])

      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: source_rel, name: "run", kind: SymbolKind::Function, line: 2)],
      )

      GraphCache.save_file_cache([
        {path: source_path, content: source, graph: graph},
      ], cache_dir, repo_key: GraphCache.default_repo_key(repo_dir))

      worktree_source = File.join(worktree_dir, source_rel)
      File.write(worktree_source, "module Demo\n  def self.changed\n  end\nend\n")
      result = GraphCache.check_file_cache([
        {path: worktree_source, content: File.read(worktree_source)},
      ], cache_dir, repo_key: GraphCache.default_repo_key(worktree_dir))

      result[:hits].should be_empty
      result[:misses].size.should eq(1)
    ensure
      FileUtils.rm_rf(worktree_dir)
      FileUtils.rm_rf(repo_dir)
      FileUtils.rm_rf(cache_dir)
    end
  end

  it "rewrites cached absolute file paths for worktree hits" do
    repo_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-paths-#{Random::Secure.hex(8)}")
    worktree_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-paths-wt-#{Random::Secure.hex(8)}")
    cache_dir = File.join(Dir.tempdir, "chiasmus-cache-worktree-paths-cache-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(repo_dir)

    begin
      run_git!(repo_dir, ["init", "-b", "main"])
      run_git!(repo_dir, ["config", "user.email", "spec@example.com"])
      run_git!(repo_dir, ["config", "user.name", "Spec User"])

      source_rel = File.join("src", "demo.cr")
      source_path = File.join(repo_dir, source_rel)
      Dir.mkdir_p(File.dirname(source_path))
      source = "module Demo\n  def self.run\n  end\nend\n"
      File.write(source_path, source)
      run_git!(repo_dir, ["add", source_rel])
      run_git!(repo_dir, ["commit", "-m", "initial cached path rewrite fixture"])
      run_git!(repo_dir, ["worktree", "add", worktree_dir, "-b", "cache-spec-path-worktree"])

      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: source_path, name: "run", kind: SymbolKind::Function, line: 2)],
        imports: [ImportsFact.new(file: source_path, name: "Demo", source: "demo")],
        exports: [ExportsFact.new(file: source_path, name: "run")],
        files: [FileNode.new(path: source_path, language: "crystal")],
        type_info: [FileTypeInfo.new(file: source_path)],
      )

      GraphCache.save_file_cache([
        {path: source_path, content: source, graph: graph},
      ], cache_dir, repo_key: GraphCache.default_repo_key(repo_dir))

      worktree_source = File.join(worktree_dir, source_rel)
      result = GraphCache.check_file_cache([
        {path: worktree_source, content: File.read(worktree_source)},
      ], cache_dir, repo_key: GraphCache.default_repo_key(worktree_dir))

      result[:misses].should be_empty
      result[:hits].size.should eq(1)
      cached_graph = result[:hits].first[:graph]
      cached_graph.defines.first.file.should eq(worktree_source)
      cached_graph.imports.first.file.should eq(worktree_source)
      cached_graph.exports.first.file.should eq(worktree_source)
      files = cached_graph.files
      raise "expected non-nil files" if files.nil?
      files.first.path.should eq(worktree_source)
      type_info = cached_graph.type_info
      raise "expected non-nil type_info" if type_info.nil?
      type_info.first.file.should eq(worktree_source)
    ensure
      FileUtils.rm_rf(worktree_dir)
      FileUtils.rm_rf(repo_dir)
      FileUtils.rm_rf(cache_dir)
    end
  end
end
