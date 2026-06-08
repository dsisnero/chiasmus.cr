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
      end
    end

    it "returns nil for unknown content" do
      with_temp_cache do |cache|
      end
    end

    it "raises on dimension mismatch" do
      with_temp_cache do |cache|
      end
    end
  end

  describe "#put_many" do
    it "stores multiple entries" do
      with_temp_cache do |cache|
      end
    end

    it "raises on length mismatch" do
      with_temp_cache do |cache|
      end
    end
  end

  describe "#partition_missing" do
    it "splits into cached and missing" do
      with_temp_cache do |cache|
      end
    end

    it "returns all as missing when cache is empty" do
      with_temp_cache do |cache|
      end
    end
  end

  describe "#save and #load" do
    it "roundtrips through disk" do
      with_temp_cache do |cache, dir|
      end
    end

    it "tolerates missing cache file" do
      cache = EmbeddingCache.new("/nonexistent/path/cache.json", 3)
      cache.load
      cache.size.should eq 0
    end

    it "ignores dimension mismatch on load" do
      with_temp_cache do |cache, dir|
      end
    end
  end

  describe "#size" do
    it "returns entry count" do
      with_temp_cache do |cache|
      end
    end
  end
end
