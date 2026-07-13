require "../../spec_helper"

module Chiasmus::Index
  def self.project_index_file_graph(path : String, name : String, callee : String) : Graph::CodeGraph
    Graph::CodeGraph.new(
      defines: [Graph::DefinesFact.new(path, name, Graph::SymbolKind::Function, 1)],
      calls: [Graph::CallsFact.new(name, callee)],
      imports: [Graph::ImportsFact.new(path, "dep", "./dep")],
      exports: [Graph::ExportsFact.new(path, name)],
      files: [Graph::FileNode.new(path, "crystal")],
    )
  end

  describe ProjectIndex do
    it "indexes definitions, files, callers, and callees" do
      index = ProjectIndex.new([
        project_index_file_graph("src/a.cr", "alpha", "beta"),
        project_index_file_graph("src/b.cr", "beta", "gamma"),
      ])

      begin
        index.definitions_named("beta").map(&.file).should eq(["src/b.cr"])
        index.definitions_in_file("src/a.cr").map(&.name).should eq(["alpha"])
        index.callers_of("beta").map(&.caller).should eq(["alpha"])
        index.callees_of("beta").map(&.callee).should eq(["gamma"])
        index.graph.files.try(&.map(&.path).sort!).should eq(["src/a.cr", "src/b.cr"])
      ensure
        index.close
      end
    end

    it "atomically replaces all stale facts for a changed file" do
      index = ProjectIndex.new([project_index_file_graph("src/a.cr", "old_name", "old_target")])

      begin
        index.upsert_file(project_index_file_graph("src/a.cr", "new_name", "new_target"))

        index.definitions_named("old_name").should be_empty
        index.callers_of("old_target").should be_empty
        index.definitions_named("new_name").map(&.file).should eq(["src/a.cr"])
        index.callees_of("new_name").map(&.callee).should eq(["new_target"])
        index.graph.files.try(&.map(&.path)).should eq(["src/a.cr"])
      ensure
        index.close
      end
    end

    it "removes every indexed fact for a deleted file" do
      index = ProjectIndex.new([project_index_file_graph("src/a.cr", "alpha", "beta")])

      begin
        index.remove_file("src/a.cr").should be_true

        index.definitions_named("alpha").should be_empty
        index.callers_of("beta").should be_empty
        index.definitions_in_file("src/a.cr").should be_empty
        index.graph.files.try(&.empty?).should be_true
      ensure
        index.close
      end
    end

    it "serializes concurrent file updates without publishing partial state" do
      index = ProjectIndex.new
      done = WaitGroup.new

      begin
        20.times do |i|
          done.add(1)
          spawn do
            index.upsert_file(project_index_file_graph("src/#{i}.cr", "f#{i}", "target"))
          ensure
            done.done
          end
        end
        done.wait

        state = index.snapshot
        state.graph.defines.size.should eq(20)
        state.callers_by_callee["target"].size.should eq(20)
        state.files_by_path.size.should eq(20)
      ensure
        index.close
      end
    end

    it "publishes a multi-file graph in one actor generation" do
      graph_a = project_index_file_graph("src/a.cr", "alpha", "beta")
      graph_b = project_index_file_graph("src/b.cr", "beta", "gamma")
      combined = Graph::CodeGraph.new(
        defines: graph_a.defines + graph_b.defines,
        calls: graph_a.calls + graph_b.calls,
        imports: graph_a.imports + graph_b.imports,
        exports: graph_a.exports + graph_b.exports,
        files: (graph_a.files || [] of Graph::FileNode) + (graph_b.files || [] of Graph::FileNode),
      )
      index = ProjectIndex.new

      begin
        before = index.snapshot.generation
        index.upsert_graph(combined)
        after = index.snapshot

        after.generation.should eq(before + 1)
        after.files_by_path.keys.sort!.should eq(["src/a.cr", "src/b.cr"])
      ensure
        index.close
      end
    end

    it "rejects a resident graph when an indexed file changes on disk" do
      dir = File.tempname("project-index-freshness")
      Dir.mkdir(dir)
      begin
        path = File.join(dir, "a.cr")
        File.write(path, "def alpha; end\n")
        index = ProjectIndex.new

        begin
          index.upsert_file(project_index_file_graph(path, "alpha", "beta"))
          index.lookup([path]).status.should eq("resident_hit")

          File.write(path, "def changed; end\n")
          stale = index.lookup([path])
          stale.status.should eq("stale")
          stale.graph.should be_nil
        ensure
          index.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "rebuilds secondary indexes from the persistent per-file cache" do
      root = File.tempname("project-index-restart")
      cache_dir = File.tempname("project-index-cache")
      Dir.mkdir(root)
      path = File.join(root, "main.go")
      File.write(path, "package main\nfunc restored() {}\n")
      repo_key = Graph::GraphCache.default_repo_key(root)

      begin
        source = Graph::SourceFile.new(path, File.read(path))
        first = Graph::Extractor.extract_graph([source], cache_dir: cache_dir, repo_key: repo_key)
        first.defines.map(&.name).should contain("restored")
        Graph::GraphCache.flush_async_writes

        restarted = ProjectIndex.new
        begin
          restarted.warm_root_async(root, cache_dir: cache_dir, repo_key: repo_key).receive.should eq(1)
          restarted.definitions_named("restored").map(&.file).should eq([path])
        ensure
          restarted.close
        end
      ensure
        FileUtils.rm_rf(root)
        FileUtils.rm_rf(cache_dir)
      end
    end
  end
end
