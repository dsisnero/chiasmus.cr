require "./grammar_loader"
require "./registry"
require "../utils/bounded_work"

module Chiasmus
  module Discovery
    # Discovery pipeline.
    #
    # Query/language caching made extraction itself cheap enough that
    # spawn-based fan-out regressed throughput in the current runtime.
    # A 40-file ExecutionContext experiment also crashed inside tree-sitter
    # node traversal, so keep this path sequential until discovery extraction
    # itself is proven thread-safe.
    class Pipeline
      @@before_async_result_send_hook = nil.as((-> Nil)?)
      @@before_async_result_send_hook_mutex = Mutex.new

      @registry : ExtractorRegistry
      @max_concurrent : Int32

      def initialize(extractors : Array(LanguageExtractor), @max_concurrent = System.cpu_count)
        @registry = ExtractorRegistry.new(extractors)
      end

      # Discover declarations across a directory.
      # Returns Result with all items and parser_mode.
      def discover(source_dir : String) : Result
        files = scan_files(source_dir)
        return Result.new(items: [] of Item, parser_mode: "tree-sitter") if files.empty?

        discover_files(files)
      end

      def discover_async(source_dir : String) : Channel(AsyncDiscoveryResult)
        channel = Channel(AsyncDiscoveryResult).new(1)

        spawn do
          begin
            result = discover(source_dir)
            self.class.run_before_async_result_send_hook
            channel.send(AsyncDiscoveryResult.new(value: result))
          rescue ex
            self.class.run_before_async_result_send_hook
            channel.send(AsyncDiscoveryResult.new(error: ex))
          end
        end

        channel
      end

      # Discover declarations from a list of (path, content) tuples.
      def discover_files(files : Array(Tuple(String, String))) : Result
        return Result.new(items: [] of Item, parser_mode: "tree-sitter") if files.empty?

        all_items = [] of Item
        Utils::BoundedWork.map_ordered(files, @max_concurrent) do |file|
          process_file(file[0], file[1])
        end.each do |items|
          next unless file_items = items
          all_items.concat(file_items)
        end

        Result.new(items: deduplicate(all_items), parser_mode: "tree-sitter")
      end

      def discover_files_async(files : Array(Tuple(String, String))) : Channel(AsyncDiscoveryResult)
        channel = Channel(AsyncDiscoveryResult).new(1)

        spawn do
          begin
            result = discover_files(files)
            self.class.run_before_async_result_send_hook
            channel.send(AsyncDiscoveryResult.new(value: result))
          rescue ex
            self.class.run_before_async_result_send_hook
            channel.send(AsyncDiscoveryResult.new(error: ex))
          end
        end

        channel
      end

      # Get all supported extensions
      def supported_extensions : Array(String)
        @registry.supported_extensions
      end

      # Get all supported languages
      def languages : Array(String)
        @registry.languages
      end

      private def process_file(file_path : String, content : String) : Array(Item)
        extractor = @registry.for_file(file_path)
        return [] of Item unless extractor

        lang = GrammarLoader.load_language(extractor.grammar_language)
        return [] of Item unless lang

        parser = TreeSitter::Parser.new(language: lang)
        tree = parser.parse(nil, content)

        extractor.extract(tree.root_node, content, file_path)
      rescue ex
        [] of Item
      end

      private def scan_files(source_dir : String) : Array(Tuple(String, String))
        files = [] of Tuple(String, String)
        extensions = @registry.supported_extensions.to_set

        Dir.glob(File.join(source_dir, "**", "*")).each do |path|
          next unless File.file?(path)
          next unless extensions.any? { |ext| path.ends_with?(ext) }

          rel = path.lchop?(source_dir).try(&.lchop?('/')) || path
          content = File.read(path)
          files << {rel, content}
        end

        files
      end

      private def deduplicate(items : Array(Item)) : Array(Item)
        seen = Set(String).new
        items.select { |item| seen.add?(item.id) }
      end

      protected def self.run_before_async_result_send_hook : Nil
        @@before_async_result_send_hook_mutex.synchronize do
          @@before_async_result_send_hook.try(&.call)
        end
      end

      def self.set_before_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_async_result_send_hook_mutex.synchronize do
          @@before_async_result_send_hook = block
        end
      end

      def self.clear_before_async_result_send_hook_for_test : Nil
        @@before_async_result_send_hook_mutex.synchronize do
          @@before_async_result_send_hook = nil
        end
      end
    end
  end
end
