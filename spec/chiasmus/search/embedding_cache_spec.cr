require "../../spec_helper"
require "../../../src/chiasmus/search/embedding_cache"

include Chiasmus::Search

private def with_temp_cache(& : EmbeddingCache, String ->)
  dir = File.tempname("chiasmus-ecache-")
  Dir.mkdir(dir)
  path = File.join(dir, "cache.json")
  cache = EmbeddingCache.new(path, 3)
  begin
    yield cache, dir
  ensure
    Dir.children(dir).each { |c| File.delete(File.join(dir, c)) rescue nil }
    Dir.delete(dir) rescue nil
  end
end

describe EmbeddingCache do
  describe "#put and #get" do
    it "stores and retrieves by content hash" do
      with_temp_cache do |cache, dir|
        cache.put("hello", [1.0, 2.0, 3.0])
        cache.get("hello").should eq [1.0, 2.0, 3.0]
      end
    end

    it "returns nil for unknown content" do
      with_temp_cache do |cache, dir|
        cache.get("unknown").should be_nil
      end
    end

    it "raises on dimension mismatch" do
      with_temp_cache do |cache, dir|
        expect_raises(ArgumentError) do
          cache.put("x", [1.0, 2.0])
        end
      end
    end
  end

  describe "#put_many" do
    it "stores multiple entries" do
      with_temp_cache do |cache, dir|
        cache.put_many(["a", "b"], [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
        cache.get("a").should eq [1.0, 0.0, 0.0]
        cache.get("b").should eq [0.0, 1.0, 0.0]
      end
    end

    it "raises on length mismatch" do
      with_temp_cache do |cache, dir|
        expect_raises(ArgumentError) do
          cache.put_many(["a", "b"], [[1.0, 0.0, 0.0]])
        end
      end
    end
  end

  describe "#partition_missing" do
    it "splits into cached and missing" do
      with_temp_cache do |cache, dir|
        cache.put("existing", [1.0, 2.0, 3.0])
        result = cache.partition_missing(["existing", "new"])
        result.cached.size.should eq 1
        result.cached[0].should eq [1.0, 2.0, 3.0]
        result.missing.should eq ["new"]
        result.missing_indexes.should eq [1]
      end
    end

    it "returns all as missing when cache is empty" do
      with_temp_cache do |cache, dir|
        result = cache.partition_missing(["a", "b"])
        result.cached.should be_empty
        result.missing.should eq ["a", "b"]
      end
    end
  end

  describe "#save and #load" do
    it "roundtrips through disk" do
      with_temp_cache do |cache, dir|
        cache.put("x", [1.0, 2.0, 3.0])
        cache.put("y", [4.0, 5.0, 6.0])
        cache.save

        restored = EmbeddingCache.new(File.join(dir, "cache.json"), 3)
        restored.load
        restored.get("x").should eq [1.0, 2.0, 3.0]
        restored.get("y").should eq [4.0, 5.0, 6.0]
        restored.size.should eq 2
      end
    end

    it "tolerates missing cache file" do
      cache = EmbeddingCache.new("/nonexistent/path/cache.json", 3)
      cache.load
      cache.size.should eq 0
    end

    it "ignores dimension mismatch on load" do
      with_temp_cache do |cache, dir|
        cache.put("x", [1.0, 2.0, 3.0])
        cache.save

        wrong_dim = EmbeddingCache.new(File.join(dir, "cache.json"), 5)
        wrong_dim.load
        wrong_dim.size.should eq 0
      end
    end
  end

  describe "#size" do
    it "returns entry count" do
      with_temp_cache do |cache, dir|
        cache.size.should eq 0
        cache.put("a", [1.0, 0.0, 0.0])
        cache.size.should eq 1
      end
    end
  end
end
