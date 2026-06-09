require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Enum and union type extraction" do
  describe "Rust enums" do
    it "captures enum name and variants" do
      code = <<-RS
        enum Color {
          Red,
          Green,
          Blue,
        }
      RS
      sources = [SourceFile.new(path: "/tmp/t.rs", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Color")
      names.should contain("Red")
      names.should contain("Green")
      names.should contain("Blue")
    end

    it "captures enum with tuple variants" do
      code = <<-RS
        enum Result {
          Ok(i32),
          Err(String),
        }
      RS
      sources = [SourceFile.new(path: "/tmp/t.rs", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Ok")
      names.should contain("Err")
    end

    it "captures enum with struct variants" do
      code = <<-RS
        enum Shape {
          Circle { radius: f64 },
          Rectangle { width: f64, height: f64 },
        }
      RS
      sources = [SourceFile.new(path: "/tmp/t.rs", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Circle")
      names.should contain("Rectangle")
    end
  end

  describe "Crystal enums" do
    it "captures enum name and members" do
      code = <<-CR
        enum Color
          Red
          Green
          Blue
        end
      CR
      sources = [SourceFile.new(path: "/tmp/t.cr", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Color")
      names.should contain("Red")
      names.should contain("Green")
      names.should contain("Blue")
    end

    it "captures flag enum with @[Flags] annotation" do
      code = <<-CR
        @[Flags]
        enum Permissions
          Read  = 1
          Write = 2
          Exec  = 4
        end
      CR
      sources = [SourceFile.new(path: "/tmp/t.cr", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Read")
      names.should contain("Write")
      names.should contain("Exec")
    end
  end

  describe "TypeScript union types" do
    it "captures type alias with union" do
      code = <<-TS
        type Status = "active" | "inactive" | "pending";
      TS
      sources = [SourceFile.new(path: "/tmp/t.ts", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Status")
    end

    it "captures discriminated union type" do
      code = <<-TS
        type Result<T> = { kind: "ok"; value: T } | { kind: "err"; error: string };
      TS
      sources = [SourceFile.new(path: "/tmp/t.ts", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Result")
    end
  end
end
