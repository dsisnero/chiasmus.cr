require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/analyses"
require "../../../src/chiasmus/graph/cache"
require "file_utils"

include Chiasmus::Graph

describe "async cache operations" do
  it "extract_graph returns result immediately, cache save completes in background" do
    tmpdir = File.join(Dir.tempdir, "async-cache-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    Dir.mkdir_p(cache_dir)
    Dir.mkdir_p(File.join(cache_dir, "default"))

    file_path = File.join(tmpdir, "test.cpp")
    File.write(file_path, "class X {};")

    begin
      graph = Extractor.extract_graph(
        [SourceFile.new(path: file_path, content: File.read(file_path))],
        cache_dir: cache_dir,
      )

      # Graph result should be immediately correct
      names = graph.defines.map(&.name).to_set
      names.should contain("X")

      # Cache file should eventually exist (give background fiber time)
      sleep(500.milliseconds)

      cache_files = Dir.glob(File.join(cache_dir, "default", "files", "*.json"))
      cache_files.should_not be_empty
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "run_analysis with save_snapshot returns correct result before snapshot is written" do
    tmpdir = File.join(Dir.tempdir, "async-snap-#{Random::Secure.hex(8)}")
    cache_dir = File.join(tmpdir, "cache")
    snap_dir = File.join(cache_dir, "default", "snapshots")
    Dir.mkdir_p(cache_dir)

    file_path = File.join(tmpdir, "test.cpp")
    File.write(file_path, "class Y { void m(); };")

    begin
      result = Analyses.run_analysis(
        [file_path],
        AnalysisRequest.new(analysis: AnalysisType::Summary),
        cache_dir: cache_dir,
        save_snapshot: "test-snap",
      )

      # Result should be immediately correct
      result_json = result.result.to_s
      result_json.should_not be_empty

      # Snapshot should eventually be written
      sleep(500.milliseconds)
      Dir.mkdir_p(snap_dir) unless Dir.exists?(snap_dir)
      snaps = Dir.glob(File.join(snap_dir, "*.json"))
      snaps.should_not be_empty
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end
end
