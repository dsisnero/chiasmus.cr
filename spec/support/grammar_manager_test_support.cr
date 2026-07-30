module TreeSitterManager
  class GrammarManager
    # Chiasmus spec-only singleton reset for isolated grammar-cache tests.
    def self.test_reset(cache_dir : String? = nil) : Nil
      @@mutex.synchronize do
        @@instance = nil
        @@cache_dir = cache_dir
        @@cache = nil
        @@initialized = false
      end
    end
  end
end
