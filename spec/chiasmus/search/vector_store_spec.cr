require "../../spec_helper"
require "json"

private def unit(v : Array(Float64)) : Array(Float64)
  sum = v.sum { |x| x * x }
  mag = sum == 0.0 ? 1.0 : Math.sqrt(sum)
  v.map { |x| x / mag }
end

describe Chiasmus::Search::VectorStore do
  it "inserts vectors and finds nearest by cosine similarity" do
    store = Chiasmus::Search::VectorStore.new(dimension: 3)
    store.add(Chiasmus::Search::VectorRecord.new(
      id: "a",
      vector: unit([1.0, 0.0, 0.0]),
      metadata: JSON::Any.new({"tag" => JSON::Any.new("x-axis")}),
    ))
    store.add(Chiasmus::Search::VectorRecord.new(
      id: "b",
      vector: unit([0.0, 1.0, 0.0]),
      metadata: JSON::Any.new({"tag" => JSON::Any.new("y-axis")}),
    ))
    store.add(Chiasmus::Search::VectorRecord.new(
      id: "c",
      vector: unit([0.0, 0.0, 1.0]),
      metadata: JSON::Any.new({"tag" => JSON::Any.new("z-axis")}),
    ))

    results = store.search(unit([0.9, 0.1, 0.0]), 2)
    results.size.should eq(2)
    results[0].id.should eq("a")
    (results[0].score > results[1].score).should be_true
    results[0].metadata.should eq(JSON::Any.new({"tag" => JSON::Any.new("x-axis")}))
  end

  it "upsert replaces an existing id" do
    store = Chiasmus::Search::VectorStore.new(dimension: 3)
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: unit([1.0, 0.0, 0.0])))
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: unit([0.0, 1.0, 0.0])))
    store.size.should eq(1)
    results = store.search(unit([0.0, 1.0, 0.0]), 1)
    results[0].id.should eq("a")
    results[0].score.should be_close(1.0, 0.001)
  end

  it "remove deletes a vector by id" do
    store = Chiasmus::Search::VectorStore.new(dimension: 2)
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: unit([1.0, 0.0])))
    store.add(Chiasmus::Search::VectorRecord.new(id: "b", vector: unit([0.0, 1.0])))
    store.remove("a").should be_true
    store.size.should eq(1)
    store.remove("nonexistent").should be_false
  end

  it "has() checks for id presence" do
    store = Chiasmus::Search::VectorStore.new(dimension: 2)
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: [1.0, 0.0]))
    store.has?("a").should be_true
    store.has?("b").should be_false
  end

  it "rejects vectors of wrong dimension" do
    store = Chiasmus::Search::VectorStore.new(dimension: 3)
    expect_raises(Chiasmus::Search::DimensionError) do
      store.add(Chiasmus::Search::VectorRecord.new(id: "bad", vector: [1.0, 0.0]))
    end
  end

  it "returns empty array when store is empty" do
    store = Chiasmus::Search::VectorStore.new(dimension: 3)
    store.search([1.0, 0.0, 0.0], 10).should eq([] of Chiasmus::Search::VectorSearchHit)
  end

  it "topK > size returns all vectors" do
    store = Chiasmus::Search::VectorStore.new(dimension: 2)
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: unit([1.0, 0.0])))
    store.add(Chiasmus::Search::VectorRecord.new(id: "b", vector: unit([0.0, 1.0])))
    results = store.search(unit([1.0, 1.0]), 10)
    results.size.should eq(2)
  end

  it "serialize → parse round-trips" do
    store = Chiasmus::Search::VectorStore.new(dimension: 2)
    store.add(Chiasmus::Search::VectorRecord.new(id: "a", vector: [1.0, 0.0], metadata: JSON::Any.new({"foo" => JSON::Any.new("bar")})))
    store.add(Chiasmus::Search::VectorRecord.new(id: "b", vector: [0.0, 1.0]))
    serialized = store.serialize
    restored = Chiasmus::Search::VectorStore.parse(serialized)
    restored.size.should eq(2)
    restored.has?("a").should be_true
    restored.has?("b").should be_true
    r = restored.search([1.0, 0.0], 1)
    r[0].id.should eq("a")
    r[0].metadata.should eq(JSON::Any.new({"foo" => JSON::Any.new("bar")}))
  end

  it "parse rejects an incompatible schema version" do
    payload = %({"schemaVersion":"999","dimension":2,"vectors":[]})
    expect_raises(Chiasmus::Search::SchemaVersionError) do
      Chiasmus::Search::VectorStore.parse(payload)
    end
  end
end
