require "tree-sitter-manager"
require "./registry"
require "../utils/bounded_work"
require "../index/fast_find"

module Chiasmus
  module Discovery
    # Discovery pipeline.
    #
    # File reads and per-file extraction are bounded with the shared worker
    # helper so directory scans can overlap without unbounded fan-out.
    # This stays on default fibers rather than ExecutionContext::Parallel
    # because the workload is dominated by file I/O plus tree-sitter parsing,
    # not proven CPU-only work.
    class Pipeline
      @@before_async_result_send_hook = nil.as((-> Nil)?)
      @@before_async_result_send_hook_mutex = Mutex.new
      @@before_scan_file_read_hook = nil.as((String -> Nil)?)
      @@before_scan_file_read_hook_mutex = Mutex.new

      @registry : ExtractorRegistry
      @max_concurrent : Int32

      def initialize(extractors : Array(LanguageExtractor), @max_concurrent = System.cpu_count.to_i32)
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

        lang = TreeSitterManager::GrammarLoader.load_language(extractor.grammar_language)
        return [] of Item unless lang

        parser = TreeSitter::Parser.new(language: lang)
        tree = parser.parse(nil, content)

        extractor.extract(tree.root_node, content, file_path)
      rescue ex
        [] of Item
      end

      private def scan_files(source_dir : String) : Array(Tuple(String, String))
        extensions = @registry.supported_extensions.to_set
        paths = [] of String

        config = FastFind::Config.new
        config.ignore_hidden = true
        config.follow_symlinks = false
        config.max_depth = 50
        walker = FastFind::Walker.new([source_dir], config)
        queue = walker.walk
        loop do
          entry = queue.receive?
          break if entry.nil?
          next unless entry.file?
          path = entry.path.to_s
          paths << path if extensions.any? { |ext| path.ends_with?(ext) }
        end

        return [] of Tuple(String, String) if paths.empty?

        Utils::BoundedWork.map_ordered_or_raise(paths, @max_concurrent) do |path|
          rel = path.lchop?(source_dir).try(&.lchop?('/')) || path
          self.class.run_before_scan_file_read_hook(path)
          content = File.read(path)
          {rel, content}
        end
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

      protected def self.run_before_scan_file_read_hook(path : String) : Nil
        hook = @@before_scan_file_read_hook_mutex.synchronize { @@before_scan_file_read_hook }
        hook.try(&.call(path))
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

      def self.set_before_scan_file_read_hook_for_test(&block : String ->) : Nil
        @@before_scan_file_read_hook_mutex.synchronize do
          @@before_scan_file_read_hook = block
        end
      end

      def self.clear_before_scan_file_read_hook_for_test : Nil
        @@before_scan_file_read_hook_mutex.synchronize do
          @@before_scan_file_read_hook = nil
        end
      end
    end
  end
end
