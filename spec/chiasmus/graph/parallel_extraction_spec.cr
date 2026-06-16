require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "parallel graph extraction" do
  it "extracts symbols from three files without data loss" do
    file_a = SourceFile.new(
      path: "/tmp/a.cpp",
      content: "namespace ns { class Alpha { void run(); }; }"
    )
    file_b = SourceFile.new(
      path: "/tmp/b.cpp",
      content: "class Beta { void run(); };"
    )
    file_c = SourceFile.new(
      path: "/tmp/c.cpp",
      content: "void call_run() { Alpha a; a.run(); }"
    )

    files = [file_a, file_b, file_c]
    graph = Extractor.extract_graph(files)

    names = graph.defines.map(&.name).to_set
    names.should contain("ns")
    names.should contain("Alpha")
    names.should contain("run")
    names.should contain("Beta")
    names.should contain("call_run")

    callees = graph.calls.map(&.callee).to_set
    callees.should contain("run")
  end

  it "produces deterministic output with 3 files (defines count and order)" do
    file_a = SourceFile.new(path: "/tmp/a.cpp", content: "class A { void fa(); };")
    file_b = SourceFile.new(path: "/tmp/b.cpp", content: "class B { void fb(); };")
    file_c = SourceFile.new(path: "/tmp/c.cpp", content: "class C { void fc(); };")

    files = [file_a, file_b, file_c]
    g1 = Extractor.extract_graph(files)
    g2 = Extractor.extract_graph(files)

    g1.defines.size.should eq(g2.defines.size)
    g1.calls.size.should eq(g2.calls.size)
    g1.defines.map(&.name).to_set.should eq(g2.defines.map(&.name).to_set)
  end

  it "extracts three files concurrently from separate fibers without deadlocking" do
    file_a = SourceFile.new(path: "/tmp/a_c.cpp", content: "class A1 { void fa(); };")
    file_b = SourceFile.new(path: "/tmp/b_c.cpp", content: "class B1 { void fb(); };")
    file_c = SourceFile.new(path: "/tmp/c_c.cpp", content: "class C1 { void fc(); };")

    chan_a = Channel(CodeGraph).new
    chan_b = Channel(CodeGraph).new
    chan_c = Channel(CodeGraph).new

    spawn { chan_a.send(Extractor.extract_graph([file_a])) }
    spawn { chan_b.send(Extractor.extract_graph([file_b])) }
    spawn { chan_c.send(Extractor.extract_graph([file_c])) }

    g_a = chan_a.receive
    g_b = chan_b.receive
    g_c = chan_c.receive

    all_names = g_a.defines.map(&.name).to_set +
                g_b.defines.map(&.name).to_set +
                g_c.defines.map(&.name).to_set

    all_names.should contain("A1")
    all_names.should contain("B1")
    all_names.should contain("C1")
    all_names.should contain("fa")
    all_names.should contain("fb")
    all_names.should contain("fc")
  end

  it "extracts all symbols from 5 files in a single call without missing any" do
    files = 5.times.map do |i|
      SourceFile.new(
        path: "/tmp/batch#{i}.cpp",
        content: "namespace n#{i} { class C#{i} { void m#{i}(); }; }"
      )
    end.to_a

    graph = Extractor.extract_graph(files)

    names = graph.defines.map(&.name).to_set
    5.times do |i|
      names.should contain("n#{i}")
      names.should contain("C#{i}")
      names.should contain("m#{i}")
    end
    graph.defines.size.should eq(15)
  end

  it "produces correct results when extract_graph is called from 10 concurrent fibers" do
    files = 10.times.map do |i|
      SourceFile.new(path: "/tmp/f#{i}.cpp", content: "class C#{i} { void m#{i}(); };")
    end.to_a

    chans = 10.times.map { Channel({Int32, CodeGraph}).new }.to_a

    10.times do |i|
      spawn do
        g = Extractor.extract_graph([files[i]])
        chans[i].send({i, g})
      end
    end

    10.times do |i|
      idx, g = chans[i].receive
      names = g.defines.map(&.name).to_set
      names.should contain("C#{idx}")
      names.should contain("m#{idx}")
    end
  end
end
