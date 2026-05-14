require "../spec_helper"

describe Chiasmus::Graph::ClojureSourceExtractor do
  describe ".extract" do
    it "extracts defn function definitions" do
      source = "(ns my.app) (defn hello [name] (println name))"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.defines.size.should eq(1)
      graph.defines.first.name.should eq("hello")
      graph.defines.first.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
    end

    it "extracts defn- as private (not exported)" do
      source = "(ns my.app) (defn- internal [x] (* x 2))"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.defines.size.should eq(1)
      graph.defines.first.name.should eq("internal")
      graph.exports.should be_empty
    end

    it "extracts defn as exported" do
      source = "(ns my.app) (defn public-fn [x] x)"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.exports.map(&.name).should contain("public-fn")
    end

    it "extracts call relationships" do
      source = "(ns my.app) (defn a [] (b)) (defn b [] 42)"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.calls.size.should eq(1)
      graph.calls.first.caller.should eq("a")
      graph.calls.first.callee.should eq("b")
    end

    it "extracts namespace-qualified calls" do
      source = "(ns my.app) (defn process [] (other.ns/helper))"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.calls.size.should eq(1)
      graph.calls.first.callee.should eq("helper")
    end

    it "extracts require imports from ns form" do
      source = "(ns my.app (:require [clojure.string :as str] [clojure.set]))"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.imports.map(&.name).should contain("clojure.string")
      graph.imports.map(&.name).should contain("clojure.set")
    end

    it "deduplicates call edges" do
      source = "(ns my.app) (defn f [] (g) (g)) (defn g [] 1)"
      file = Chiasmus::Graph::SourceFile.new(path: "test.clj", content: source)
      graph = Chiasmus::Graph::ClojureSourceExtractor.extract(file)

      graph.calls.size.should eq(1)
    end
  end
end
