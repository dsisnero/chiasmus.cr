require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Proto graph walker" do
  it "extracts message definitions" do
    code = <<-PROTO
      syntax = "proto3";
      message Person {
        string name = 1;
        int32 age = 2;
      }
    PROTO
    sources = [SourceFile.new(path: "/tmp/t.proto", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("Person")
  end

  it "extracts service and rpc definitions" do
    code = <<-PROTO
      syntax = "proto3";
      service Greeter {
        rpc SayHello (HelloRequest) returns (HelloReply);
      }
    PROTO
    sources = [SourceFile.new(path: "/tmp/t.proto", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Greeter")
    names.should contain("SayHello")
  end

  it "captures import statements" do
    code = <<-PROTO
      syntax = "proto3";
      import "google/protobuf/timestamp.proto";
      import "other.proto";
      message Foo {}
    PROTO
    sources = [SourceFile.new(path: "/tmp/t.proto", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 2
  end

  it "produces file nodes for Proto files" do
    code = "syntax = \"proto3\";\nmessage Foo {}\n"
    sources = [SourceFile.new(path: "/tmp/t.proto", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("proto")
  end
end
