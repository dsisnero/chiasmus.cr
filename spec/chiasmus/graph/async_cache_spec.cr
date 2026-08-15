require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/analyses"
require "../../../src/chiasmus/graph/cache"
require "file_utils"

include Chiasmus::Graph

describe "async cache persistence" do
  it "extract_graph returns before cache persistence completes, then flush writes the cache" do
    tmpdir = File.join(Dir.tempdir, "async-cache-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    Dir.mkdir_p(cache_dir)

    file_path = File.join(tmpdir, "test.cr")
    File.write(file_path, "class X\nend\n")

    begin
      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)
      result_chan = Channel(CodeGraph).new(1)

      GraphCache.set_before_file_cache_write_hook_for_test do
        entered.send(true)
        release.receive?
      end

      spawn do
        graph = Extractor.extract_graph(
          [SourceFile.new(path: file_path, content: File.read(file_path))],
          cache_dir: cache_dir,
        )
        result_chan.send(graph)
      end

      entered.receive
      graph = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
      graph.should_not be_nil

      cached_graph = graph || raise "expected cached graph"
      names = cached_graph.defines.map(&.name).to_set
      names.should contain("X")

      before_flush = GraphCache.check_file_cache([{path: file_path, content: File.read(file_path)}], cache_dir)
      before_flush[:hits].should be_empty

      release.send(true)
      GraphCache.flush_async_writes

      after_flush = GraphCache.check_file_cache([{path: file_path, content: File.read(file_path)}], cache_dir)
      after_flush[:hits].size.should eq(1)
    ensure
      GraphCache.clear_before_file_cache_write_hook_for_test
      GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "run_analysis returns before snapshot persistence completes, then flush writes the snapshot" do
    tmpdir = File.join(Dir.tempdir, "async-snap-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    repo_key = GraphCache.default_repo_key(Dir.current)
    Dir.mkdir_p(cache_dir)

    file_path = File.join(tmpdir, "test.cr")
    File.write(file_path, "class Y\n  def m\n  end\nend\n")

    begin
      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)
      result_chan = Channel(AnalysisResult).new(1)

      GraphCache.set_before_snapshot_write_hook_for_test do
        entered.send(true)
        release.receive?
      end

      spawn do
        result = Analyses.run_analysis(
          [file_path],
          AnalysisRequest.new(analysis: AnalysisType::Summary),
          cache_dir: cache_dir,
          save_snapshot: "test-snap",
        )
        result_chan.send(result)
      end

      entered.receive
      result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
      result.should_not be_nil

      graph_result = result || raise "expected async cache graph result"
      result_json = graph_result.result.to_s
      result_json.should_not be_empty

      snap_dir = File.join(cache_dir, repo_key, "snapshots")
      snaps = Dir.glob(File.join(snap_dir, "*.json"))
      snaps.should be_empty

      release.send(true)
      GraphCache.flush_async_writes

      snaps = Dir.glob(File.join(snap_dir, "*.json"))
      snaps.should_not be_empty
    ensure
      GraphCache.clear_before_snapshot_write_hook_for_test
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "flushes snapshots without waiting for queued file-cache writes" do
    tmpdir = File.join(Dir.tempdir, "snapshot-only-flush-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    repo_key = GraphCache.default_repo_key(Dir.current)
    Dir.mkdir_p(cache_dir)

    file_path = File.join(tmpdir, "queued.cr")
    File.write(file_path, "class Queued; end\n")
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    flushed = Channel(Bool).new(1)

    begin
      GraphCache.set_before_file_cache_write_hook_for_test do
        entered.send(true)
        release.receive?
      end

      Extractor.extract_graph(
        [SourceFile.new(path: file_path, content: File.read(file_path))],
        cache_dir: cache_dir,
      )
      entered.receive

      GraphCache.save_snapshot_async("independent", CodeGraph.new, cache_dir, repo_key: repo_key)
      spawn do
        GraphCache.flush_snapshot_writes
        flushed.send(true)
      end

      TreeSitterManager::Timeout.with_timeout_async(250, flushed).should be_true
      GraphCache.list_snapshots(cache_dir, repo_key: repo_key).should contain("independent")
    ensure
      release.send(true) unless release.closed?
      GraphCache.clear_before_file_cache_write_hook_for_test
      GraphCache.flush_async_writes
      GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "persists an unrelated snapshot while another snapshot is blocked" do
    tmpdir = File.join(Dir.tempdir, "independent-snapshot-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    repo_key = "independent-snapshot-spec"
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    finished = Channel(Bool).new(1)
    hook_mutex = Mutex.new
    first_write = true

    begin
      GraphCache.set_before_snapshot_write_hook_for_test do
        should_block = hook_mutex.synchronize do
          block = first_write
          first_write = false
          block
        end
        if should_block
          entered.send(true)
          release.receive?
        end
      end

      GraphCache.save_snapshot_async("blocked", CodeGraph.new, cache_dir, repo_key: repo_key)
      entered.receive

      spawn do
        GraphCache.save_snapshot_async_and_wait("independent", CodeGraph.new, cache_dir, repo_key: repo_key)
        finished.send(true)
      end

      TreeSitterManager::Timeout.with_timeout_async(250, finished).should be_true
      GraphCache.load_snapshot("independent", cache_dir, repo_key: repo_key).should_not be_nil
    ensure
      release.send(true) unless release.closed?
      GraphCache.clear_before_snapshot_write_hook_for_test
      GraphCache.flush_snapshot_writes
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "coalesces queued retries for the same snapshot target" do
    tmpdir = File.join(Dir.tempdir, "coalesced-snapshot-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    repo_key = "coalesced-snapshot-spec"
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    finished = Channel(Bool).new(2)
    hook_mutex = Mutex.new
    write_count = 0

    first = CodeGraph.new(defines: [DefinesFact.new(file: "first.cr", name: "first", kind: SymbolKind::Function, span: Span.line_range(1))])
    latest = CodeGraph.new(defines: [DefinesFact.new(file: "latest.cr", name: "latest", kind: SymbolKind::Function, span: Span.line_range(1))])

    begin
      GraphCache.set_before_snapshot_write_hook_for_test do
        block_first = hook_mutex.synchronize do
          write_count += 1
          write_count == 1
        end
        if block_first
          entered.send(true)
          release.receive?
        end
      end

      GraphCache.save_snapshot_async("retry", first, cache_dir, repo_key: repo_key)
      entered.receive
      spawn do
        GraphCache.save_snapshot_async_and_wait("retry", first, cache_dir, repo_key: repo_key)
        finished.send(true)
      end
      spawn do
        GraphCache.save_snapshot_async_and_wait("retry", latest, cache_dir, repo_key: repo_key)
        finished.send(true)
      end

      release.send(true)
      finished.receive.should be_true
      finished.receive.should be_true

      hook_mutex.synchronize { write_count }.should eq(2)
      snapshot = GraphCache.load_snapshot("retry", cache_dir, repo_key: repo_key)
      snapshot.not_nil!.defines.map(&.name).should eq(["latest"])
    ensure
      release.send(true) unless release.closed?
      GraphCache.clear_before_snapshot_write_hook_for_test
      GraphCache.flush_snapshot_writes
      FileUtils.rm_rf(tmpdir)
    end
  end
end
