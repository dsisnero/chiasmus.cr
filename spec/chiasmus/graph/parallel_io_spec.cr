require "../../spec_helper"
require "../../../src/chiasmus/graph/parallel_io"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "file_utils"

describe "parallel file I/O in graph extraction" do
  it "read_source_files_parallel reads all files and preserves paths" do
    tmpdir = File.join(Dir.tempdir, "parallel-io-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(tmpdir)

    paths = 5.times.map do |i|
      path = File.join(tmpdir, "f#{i}.cpp")
      File.write(path, "class C#{i} {};")
      path
    end.to_a

    begin
      sources = Chiasmus::Graph::FileIO.read_source_files_parallel(paths)

      sources.size.should eq(5)
      paths_set = paths.to_set
      sources.each do |src|
        paths_set.should contain(src.path)
        src.content.should contain("class C")
      end
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "read_source_files_parallel handles 10 files without data loss" do
    tmpdir = File.join(Dir.tempdir, "parallel-io-10-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(tmpdir)

    paths = 10.times.map do |i|
      path = File.join(tmpdir, "g#{i}.cr")
      File.write(path, "module N#{i}\n  def f#{i}\n  end\nend\n")
      path
    end.to_a

    begin
      sources = Chiasmus::Graph::FileIO.read_source_files_parallel(paths)
      graph = Chiasmus::Graph::Extractor.extract_graph(sources)

      names = graph.defines.map(&.name).to_set
      10.times do |i|
        names.should contain("N#{i}")
        names.should contain("f#{i}")
      end
      graph.defines.size.should eq(20)
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  it "read_source_files_parallel respects the max_concurrent bound" do
    tmpdir = File.join(Dir.tempdir, "parallel-io-bounded-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(tmpdir)

    paths = 6.times.map do |i|
      path = File.join(tmpdir, "bounded#{i}.txt")
      File.write(path, "file #{i}")
      path
    end.to_a

    active = 0
    peak = 0
    mutex = Mutex.new

    begin
      sources = Chiasmus::Graph::FileIO.read_source_files_parallel(paths, 2) do |path|
        mutex.synchronize do
          active += 1
          peak = {peak, active}.max
        end

        sleep 20.milliseconds
        File.read(path)
      ensure
        mutex.synchronize do
          active -= 1
        end
      end

      sources.size.should eq(6)
      peak.should be <= 2
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end
end
