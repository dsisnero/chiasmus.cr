require "../../spec_helper"
require "../../../src/chiasmus/search/vector_store"

include Chiasmus::Search

describe VectorStore do
  describe "#add and #search" do
    it "returns top-K hits by cosine similarity" do
      store = VectorStore.new(3)
      store.add(VectorRecord.new(metadata: nil, id: "a", vector: [1.0, 0.0, 0.0]))
      store.add(VectorRecord.new(metadata: nil, id: "b", vector: [0.0, 1.0, 0.0]))
      store.add(VectorRecord.new(metadata: nil, id: "c", vector: [0.0, 0.0, 1.0]))

      results = store.search([1.0, 0.0, 0.0], 2)
      results.size.should eq 2
      results[0].id.should eq "a"
      results[0].score.should be_close(1.0, 0.001)
    end

    it "returns empty array for empty store" do
      store = VectorStore.new(3)
      results = store.search([1.0, 0.0, 0.0], 5)
      results.should be_empty
    end

    it "returns empty array for top_k <= 0" do
      store = VectorStore.new(3)
      store.add(VectorRecord.new(metadata: nil, id: "a", vector: [1.0, 0.0, 0.0]))
      results = store.search([1.0, 0.0, 0.0], 0)
      results.should be_empty
    end

    it "skips zero-norm vectors" do
      store = VectorStore.new(2)
      store.add(VectorRecord.new(metadata: nil, id: "zero", vector: [0.0, 0.0]))
      store.add(VectorRecord.new(metadata: nil, id: "one", vector: [1.0, 0.0]))
      results = store.search([1.0, 0.0], 5)
      results.size.should eq 1
      results[0].id.should eq "one"
    end

    it "raises on dimension mismatch" do
      store = VectorStore.new(2)
      expect_raises(ArgumentError) do
        store.add(VectorRecord.new(metadata: nil, id: "x", vector: [1.0, 2.0, 3.0]))
      end
    end

    it "raises on query dimension mismatch" do
      store = VectorStore.new(2)
      store.add(VectorRecord.new(metadata: nil, id: "a", vector: [1.0, 0.0]))
      expect_raises(ArgumentError) do
        store.search([1.0, 2.0, 3.0], 5)
      end
    end
  end

  describe "#remove" do
    it "removes entries by id" do
      store = VectorStore.new(2)
      store.add(VectorRecord.new(metadata: nil, id: "a", vector: [1.0, 0.0]))
      store.add(VectorRecord.new(metadata: nil, id: "b", vector: [0.0, 1.0]))
      store.remove("a").should be_true
      store.has?("a").should be_false
      store.has?("b").should be_true
      store.size.should eq 1
    end

    it "returns false for missing id" do
      store = VectorStore.new(2)
      store.remove("nope").should be_false
    end
  end

  describe "#ids" do
    it "returns all stored ids" do
      store = VectorStore.new(2)
      store.add(VectorRecord.new(metadata: nil, id: "a", vector: [1.0, 0.0]))
      store.add(VectorRecord.new(metadata: nil, id: "b", vector: [0.0, 1.0]))
      store.ids.sort.should eq ["a", "b"]
    end
  end

  describe "serialize/parse roundtrip" do
    it "roundtrips through JSON" do
      store = VectorStore.new(3)
      store.add(VectorRecord.new(metadata: nil, id: "x", vector: [1.0, 2.0, 3.0]))
      store.add(VectorRecord.new(metadata: nil, id: "y", vector: [4.0, 5.0, 6.0]))

      json = store.serialize
      restored = VectorStore.parse(json)

      restored.size.should eq 2
      restored.has?("x").should be_true
      restored.has?("y").should be_true

      results = restored.search([1.0, 2.0, 3.0], 1)
      results.first.id.should eq "x"
    end
  end
end
