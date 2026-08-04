require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

private class TrackingParser
  getter max_active

  def initialize(@language : String)
    @active = 0
    @max_active = 0
    @mutex = Mutex.new
  end

  def language_for_file(_path : String) : String?
    @language
  end

  def parse_source(_content : String, _file_path : String) : TreeSitter::Tree?
    @mutex.synchronize do
      @active += 1
      @max_active = Math.max(@max_active, @active)
    end

    sleep 10.milliseconds
    nil
  ensure
    @mutex.synchronize do
      @active -= 1
    end
  end
end

private class PrewarmingParserService < Chiasmus::Graph::Parser::Service
  getter warmed_languages = [] of String

  def get_language(language : String, timeout_ms : Int32 = 60_000) : TreeSitter::Language?
    @warmed_languages << language
    nil
  end

  def parse(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
    nil
  end
end

describe "parallel graph extraction" do
  it "prewarms the Crystal grammar before default extraction" do
    previous_service = Parser.service
    service = PrewarmingParserService.new
    Parser.service = service

    begin
      Extractor.extract_graph([SourceFile.new(path: "/tmp/prewarm.cr", content: "class Prewarm; end\n")])

      service.warmed_languages.should eq(["crystal"])
    ensure
      Parser.service = previous_service
    end
  end

  it "extracts symbols from three files without data loss" do
    file_a = SourceFile.new(
      path: "/tmp/a.cr",
      content: "module Ns\n  class Alpha\n    def run\n    end\n  end\nend\n"
    )
    file_b = SourceFile.new(
      path: "/tmp/b.cr",
      content: "class Beta\n  def run\n  end\nend\n"
    )
    file_c = SourceFile.new(
      path: "/tmp/c.cr",
      content: "def call_run\n  Ns::Alpha.new.run\nend\n"
    )

    files = [file_a, file_b, file_c]
    graph = Extractor.extract_graph(files)

    names = graph.defines.map(&.name).to_set
    names.should contain("Ns")
    names.should contain("Alpha")
    names.should contain("run")
    names.should contain("Beta")
    names.should contain("call_run")

    callees = graph.calls.map(&.callee).to_set
    callees.should contain("run")
  end

  it "extract_graph_async returns a channel before the result is released" do
    file = SourceFile.new(
      path: "/tmp/async_extract.cr",
      content: "class AsyncExtract\n  def run\n  end\nend\n"
    )
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)

    Extractor.set_before_async_result_send_hook_for_test do
      entered.send(true)
      release.receive?
    end

    begin
      result_channel = Extractor.extract_graph_async([file])

      entered.receive.should be_true

      select
      when result_channel.receive?
        fail("expected async extraction result to remain pending until released")
      else
      end

      release.send(true)
      result = result_channel.receive?
      result.should_not be_nil
      extraction = result || raise "expected async extraction result"
      extraction.defines.map(&.name).to_set.should contain("AsyncExtract")
      result_channel.receive?.should be_nil
    ensure
      Extractor.clear_before_async_result_send_hook_for_test
    end
  end

  it "produces deterministic output with 3 files (defines count and order)" do
    file_a = SourceFile.new(path: "/tmp/a.cr", content: "class A\n  def fa\n  end\nend\n")
    file_b = SourceFile.new(path: "/tmp/b.cr", content: "class B\n  def fb\n  end\nend\n")
    file_c = SourceFile.new(path: "/tmp/c.cr", content: "class C\n  def fc\n  end\nend\n")

    files = [file_a, file_b, file_c]
    g1 = Extractor.extract_graph(files)
    g2 = Extractor.extract_graph(files)

    g1.defines.size.should eq(g2.defines.size)
    g1.calls.size.should eq(g2.calls.size)
    g1.defines.map(&.name).to_set.should eq(g2.defines.map(&.name).to_set)
  end

  it "produces equivalent graphs with sequential and bounded-concurrent extraction" do
    files = 6.times.map do |i|
      SourceFile.new(
        path: "/tmp/equivalent#{i}.cr",
        content: "module N#{i}\n  class C#{i}\n    def m#{i}\n      C#{i}.new\n    end\n  end\nend\n"
      )
    end.to_a

    sequential = Extractor.extract_graph(files, max_concurrent: 1)
    concurrent = Extractor.extract_graph(files, max_concurrent: 3)

    sequential.defines.map(&.name).to_set.should eq(concurrent.defines.map(&.name).to_set)
    sequential.calls.map { |fact| {fact.caller, fact.callee} }.to_set.should eq(
      concurrent.calls.map { |fact| {fact.caller, fact.callee} }.to_set
    )
    sequential.imports.should eq(concurrent.imports)
    sequential.exports.should eq(concurrent.exports)
    sequential.contains.map { |fact| {fact.parent, fact.child} }.to_set.should eq(
      concurrent.contains.map { |fact| {fact.parent, fact.child} }.to_set
    )
  end

  it "produces equivalent graphs when cpu-parallel extraction is requested" do
    files = 6.times.map do |i|
      SourceFile.new(
        path: "/tmp/parallel_cpu#{i}.cr",
        content: "module P#{i}\n  class K#{i}\n    def work#{i}\n      K#{i}.new\n    end\n  end\nend\n"
      )
    end.to_a

    baseline = Extractor.extract_graph(files, max_concurrent: 1)
    parallel = Extractor.extract_graph(files, max_concurrent: 3, parallel_cpu: true)

    baseline.defines.map(&.name).to_set.should eq(parallel.defines.map(&.name).to_set)
    baseline.calls.map { |fact| {fact.caller, fact.callee} }.to_set.should eq(
      parallel.calls.map { |fact| {fact.caller, fact.callee} }.to_set
    )
    baseline.contains.map { |fact| {fact.parent, fact.child} }.to_set.should eq(
      parallel.contains.map { |fact| {fact.parent, fact.child} }.to_set
    )
  end

  it "uses bounded concurrency for Crystal parsing by default" do
    parser = TrackingParser.new("crystal")
    files = 4.times.map do |i|
      SourceFile.new(path: "/tmp/cold#{i}.cr", content: "def sample#{i}; end\n")
    end.to_a

    Extractor.extract_graph(files, parser, max_concurrent: 4)

    parser.max_active.should be > 1
    parser.max_active.should be <= 4
  end

  it "keeps bounded concurrency for non-crystal languages" do
    parser = TrackingParser.new("go")
    files = 4.times.map do |i|
      SourceFile.new(path: "/tmp/cold#{i}.go", content: "package demo\n")
    end.to_a

    Extractor.extract_graph(files, parser, max_concurrent: 4)

    parser.max_active.should be > 1
  end

  it "extracts three files concurrently from separate fibers without deadlocking" do
    file_a = SourceFile.new(path: "/tmp/a_c.cr", content: "class A1\n  def fa\n  end\nend\n")
    file_b = SourceFile.new(path: "/tmp/b_c.cr", content: "class B1\n  def fb\n  end\nend\n")
    file_c = SourceFile.new(path: "/tmp/c_c.cr", content: "class C1\n  def fc\n  end\nend\n")

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
        path: "/tmp/batch#{i}.cr",
        content: "module N#{i}\n  class C#{i}\n    def m#{i}\n    end\n  end\nend\n"
      )
    end.to_a

    graph = Extractor.extract_graph(files)

    names = graph.defines.map(&.name).to_set
    5.times do |i|
      names.should contain("N#{i}")
      names.should contain("C#{i}")
      names.should contain("m#{i}")
    end
    graph.defines.size.should eq(15)
  end

  it "produces correct results when extract_graph is called from 10 concurrent fibers" do
    files = 10.times.map do |i|
      SourceFile.new(path: "/tmp/f#{i}.cr", content: "class C#{i}\n  def m#{i}\n  end\nend\n")
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
