require "../../spec_helper"

include Chiasmus::Graph

# Regression for the teardown faults.
#
# `close_file_cache_stores` cleared `@@stores` *before* closing the handles, and
# `sqlite_store` handed store references to callers that used them outside
# `@@store_mutex`. A watcher callback landing in that window either used a
# closed handle (a native fault, seen in the field as SIGBUS with no Crystal
# backtrace) or silently reopened the database after shutdown.
describe GraphCache do
  it "refuses to serve stores once they are closed" do
    dir = File.tempname("chiasmus-cache-closed")
    Dir.mkdir_p(dir)
    begin
      GraphCache.close_file_cache_stores

      expect_raises(GraphCache::CacheClosedError) do
        GraphCache.invalidate_file_cache([File.join(dir, "a.cr")], dir)
      end
    ensure
      GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "survives a concurrent invalidation racing a close" do
    dir = File.tempname("chiasmus-cache-race")
    Dir.mkdir_p(dir)
    begin
      paths = Array.new(20) { |index| File.join(dir, "file#{index}.cr") }
      results = Channel(Exception?).new(paths.size)

      paths.each do |path|
        spawn do
          begin
            GraphCache.invalidate_file_cache([path], dir)
            results.send(nil)
          rescue ex
            results.send(ex)
          end
        end
      end

      GraphCache.close_file_cache_stores

      errors = [] of Exception
      paths.size.times do
        if error = results.receive
          errors << error
        end
      end

      # Racing callers may either complete or be told the cache is gone; what
      # must never happen is a crash from using a closed handle.
      errors.each { |error| error.should be_a(GraphCache::CacheClosedError) }
    ensure
      GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
