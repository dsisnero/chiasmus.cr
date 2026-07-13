require "../../spec_helper"
require "../../../src/chiasmus/discovery"
require "../../../src/chiasmus/graph/extractor"

describe "Crystal query and walker extraction strategies" do
  it "agrees on definitions while preserving graph relationships in the walker" do
    source = <<-CR
      require "json"

      module Demo
        class Worker
          def run(value)
            helper(value)
          end

          def helper(value)
            value.to_s
          end
        end
      end
    CR
    path = "/tmp/crystal_strategy.cr"

    query_result = Chiasmus::Discovery.discover_file("crystal", source, path)
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new(path: path, content: source),
    ])

    query_names = query_result.items.reject(&.kind.starts_with?("reference.")).map(&.name).to_set
    graph_names = graph.defines.map(&.name.split('.').last).to_set

    query_names.should contain("Demo")
    query_names.should contain("Worker")
    query_names.should contain("run")
    query_names.should contain("helper")
    graph_names.should contain("Demo")
    graph_names.should contain("Worker")
    graph_names.should contain("run")
    graph_names.should contain("helper")

    query_result.items.any? { |item| item.kind == "reference.call" && item.name == "helper" }.should be_true
    graph.calls.any? { |fact| fact.caller.ends_with?("run") && fact.callee == "helper" }.should be_true
    graph.contains.any? { |fact| fact.parent.ends_with?("Worker") && fact.child.ends_with?("run") }.should be_true
    graph.imports.any? { |fact| fact.source == "json" }.should be_true
  end

  it "keeps parsed trees alive through repeated query and walker traversal" do
    source = String.build do |io|
      io << "class Worker\n"
      30.times do |index|
        io << "  def step_#{index}(value)\n"
        io << "    value.to_s\n"
        io << "  end\n"
      end
      io << "end\n"
    end

    20.times do |index|
      GC.collect
      path = "/tmp/crystal_lifetime_#{index}.cr"
      query_result = Chiasmus::Discovery.discover_file("crystal", source, path)
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new(path: path, content: source),
      ])

      query_result.items.count { |item| item.kind == "method" }.should eq(30)
      graph.defines.count(&.name.includes?("step_")).should eq(30)
    end
  end
end
