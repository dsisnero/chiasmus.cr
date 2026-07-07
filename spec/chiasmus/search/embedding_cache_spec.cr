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
    Dir.children(dir).each { |child| File.delete(File.join(dir, child)) rescue nil }
    Dir.delete(dir) rescue nil
  end
end

describe EmbeddingCache do
  describe "#put and #get" do
    it "stores and retrieves by content hash" do
      with_temp_cache do |cache|
        cache.put("hello", [1.0, 2.0, 3.0])
        cache.get("hello").should eq [1.0, 2.0, 3.0]
      end
    end

    it "returns nil for unknown content" do
      with_temp_cache do |cache|
        cache.get("unknown").should be_nil
      end
    end

    it "raises on dimension mismatch" do
      with_temp_cache do |cache|
        expect_raises(ArgumentError) do
          cache.put("x", [1.0, 2.0])
        end
      end
    end

    it "returns a copy so callers cannot mutate the cached vector" do
      with_temp_cache do |cache|
        cache.put("hello", [1.0, 2.0, 3.0])

        vector = cache.get("hello")
        vector.should_not be_nil
        vector = vector || raise "expected cached vector"
        vector[0] = 99.0

        cache.get("hello").should eq [1.0, 2.0, 3.0]
      end
    end
  end

  describe "#put_many" do
    it "stores multiple entries" do
      with_temp_cache do |cache|
        cache.put_many(["a", "b"], [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
        cache.get("a").should eq [1.0, 0.0, 0.0]
        cache.get("b").should eq [0.0, 1.0, 0.0]
      end
    end

    it "raises on length mismatch" do
      with_temp_cache do |cache|
        expect_raises(ArgumentError) do
          cache.put_many(["a", "b"], [[1.0, 0.0, 0.0]])
        end
      end
    end
  end

  describe "#partition_missing" do
    it "splits into cached and missing" do
      with_temp_cache do |cache|
        cache.put("existing", [1.0, 2.0, 3.0])
        result = cache.partition_missing(["existing", "new"])
        result.cached.size.should eq 1
        result.cached[0].should eq [1.0, 2.0, 3.0]
        result.missing.should eq ["new"]
        result.missing_indexes.should eq [1]
      end
    end

    it "returns all as missing when cache is empty" do
      with_temp_cache do |cache|
        result = cache.partition_missing(["a", "b"])
        result.cached.should be_empty
        result.missing.should eq ["a", "b"]
      end
    end

    it "returns cached vectors as copies so partition results cannot mutate the cache" do
      with_temp_cache do |cache|
        cache.put("existing", [1.0, 2.0, 3.0])

        result = cache.partition_missing(["existing"])
        result.cached[0][0] = 42.0

        cache.get("existing").should eq [1.0, 2.0, 3.0]
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

    it "keeps later writes dirty when a put races with an in-flight save" do
      with_temp_cache do |cache, dir|
        entered_hook = Channel(Bool).new(1)
        release_hook = Channel(Bool).new(1)
        save_done = Channel(Bool).new(1)

        cache.set_before_dirty_clear_hook_for_test do
          entered_hook.send(true)
          release_hook.receive
        end

        begin
          cache.put("early", [1.0, 2.0, 3.0])

          spawn do
            cache.save
            save_done.send(true)
          end

          TreeSitterManager::Timeout.with_timeout_async(500, entered_hook).should eq(true)
          cache.put("late", [4.0, 5.0, 6.0])
          release_hook.send(true)
          TreeSitterManager::Timeout.with_timeout_async(500, save_done).should eq(true)
          cache.clear_before_dirty_clear_hook_for_test

          cache.save

          restored = EmbeddingCache.new(File.join(dir, "cache.json"), 3)
          restored.load
          restored.get("early").should eq [1.0, 2.0, 3.0]
          restored.get("late").should eq [4.0, 5.0, 6.0]
        ensure
          cache.clear_before_dirty_clear_hook_for_test
        end
      end
    end
  end

  describe "#size" do
    it "returns entry count" do
      with_temp_cache do |cache|
        cache.size.should eq 0
        cache.put("a", [1.0, 0.0, 0.0])
        cache.size.should eq 1
      end
    end
  end
end
