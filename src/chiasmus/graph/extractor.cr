require "./parser"
require "./walkers"
require "./adapter_registry"
require "./clojure_source_extractor"
require "./type_env"
require "./resolve_calls"
require "./cache"
require "./parallel_io"
require "../utils/bounded_work"
require "tracing"

module Chiasmus
  module Graph
    module Extractor
      extend self

      @@merge_mutex = Mutex.new
      @@before_async_result_send_hook = nil.as((-> Nil)?)
      DEFAULT_MAX_CONCURRENT = Utils::BoundedWork::DEFAULT_MAX_CONCURRENT

      def extract_graph(
        files : Array(SourceFile),
        parser = Parser,
        cache_dir : String? = nil,
        repo_key : String? = nil,
        max_bytes : Int32? = nil,
        max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
        parallel_cpu : Bool = parallel_cpu_enabled?,
      ) : CodeGraph
        started_at = Time.instant
        telemetry_span = Tracing.span(Tracing::Level::INFO, "chiasmus.graph.extract", files: files.size)
        to_extract = files
        cached = [] of NamedTuple(path: String, graph: CodeGraph)

        cache_error = nil.as(String?)

        if cache_dir
          begin
            check_result = GraphCache.check_file_cache(
              files.map { |file_info| {path: file_info.path, content: file_info.content} },
              cache_dir,
              repo_key: repo_key,
            )
            cached = check_result[:hits]
            to_extract = check_result[:misses].map { |miss| SourceFile.new(path: miss[:path], content: miss[:content]) }
          rescue ex
            cache_error = ex.message || ex.class.name
            STDERR.puts "[Chiasmus] graph cache unavailable for #{cache_dir}: #{cache_error}; continuing without cache"
            cached = [] of NamedTuple(path: String, graph: CodeGraph)
            to_extract = files
          end
        end

        cache_status = if cache_dir.nil?
                         "disabled"
                       elsif cache_error
                         "cache_error"
                       elsif cached.size == files.size
                         "disk_hit"
                       elsif cached.empty?
                         "extracted"
                       else
                         "partial_hit"
                       end

        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        contains = [] of ContainsFact
        type_info = [] of FileTypeInfo
        file_nodes = [] of FileNode
        call_set = Set(String).new
        fresh_graphs = [] of {path: String, content: String, graph: CodeGraph}

        prewarm_crystal_grammar(to_extract, parser)

        fresh_results = Utils::BoundedWork.map_ordered(to_extract, max_concurrent, parallel: parallel_cpu) do |file|
          extract_single_file(file, parser)
        end

        fresh_results.compact_map(&.itself).each do |fresh_graph|
          unless fresh_graph.defines.empty? &&
                 fresh_graph.calls.empty? &&
                 fresh_graph.imports.empty? &&
                 (fresh_graph.files.nil? || fresh_graph.files.try(&.empty?))
            merge_graph_under_lock(
              fresh_graph,
              defines, calls, imports, exports, contains,
              file_nodes, type_info, call_set
            )
            # Find original source file for caching
            if matching_file = to_extract.find { |file| file.path == fresh_graph.files.try(&.first?.try(&.path)) }
              fresh_graphs << {path: matching_file.path, content: matching_file.content, graph: fresh_graph}
            end
          end
        end

        if cache_dir && !fresh_graphs.empty?
          dir = cache_dir
          limit = max_bytes || GraphCache.default_max_bytes_per_repo
          GraphCache.save_file_cache_async(fresh_graphs, dir, repo_key: repo_key, max_bytes: limit)
        end

        # Merge cached graphs
        cached.each do |entry|
          merge_cached_graph(entry[:graph], defines, calls, imports, exports, contains, file_nodes, type_info, call_set)
        end

        graph = CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports,
          exports: exports,
          contains: contains,
          files: file_nodes.empty? ? nil : file_nodes,
          type_info: type_info.empty? ? nil : type_info
        )
        telemetry_span.record(
          cache_status: cache_status,
          disk_hits: cached.size,
          files_reindexed: to_extract.size,
          extraction_ms: (Time.instant - started_at).total_milliseconds,
        )
        Tracing.info(
          "chiasmus.graph.extract.complete",
          cache_status: cache_status,
          disk_hits: cached.size,
          files_reindexed: to_extract.size,
          extraction_ms: (Time.instant - started_at).total_milliseconds,
        )
        graph
      end

      def extract_graph_async(
        files : Array(SourceFile),
        parser = Parser,
        cache_dir : String? = nil,
        repo_key : String? = nil,
        max_bytes : Int32? = nil,
        max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
        parallel_cpu : Bool = parallel_cpu_enabled?,
      ) : Channel(CodeGraph)
        channel = Channel(CodeGraph).new(1)

        spawn do
          begin
            result = extract_graph(
              files,
              parser,
              cache_dir: cache_dir,
              repo_key: repo_key,
              max_bytes: max_bytes,
              max_concurrent: max_concurrent,
              parallel_cpu: parallel_cpu
            )
            @@before_async_result_send_hook.try(&.call)
            channel.send(result)
          ensure
            channel.close
          end
        end

        channel
      end

      def set_before_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_async_result_send_hook = block
      end

      def clear_before_async_result_send_hook_for_test : Nil
        @@before_async_result_send_hook = nil
      end

      private def parallel_cpu_enabled? : Bool
        ENV["CHIASMUS_GRAPH_PARALLEL"]? == "1"
      end

      # Load Crystal once before file workers begin. This keeps grammar setup out
      # of the first file's extraction path and lets concurrent workers reuse
      # Parser's synchronized language cache. Injected parsers retain complete
      # control over their own lifecycle.
      private def prewarm_crystal_grammar(files : Array(SourceFile), parser) : Nil
        return unless parser == Parser
        return unless files.any? { |file| parser.language_for_file(file.path) == "crystal" }

        Parser.get_language("crystal", 30_000)
      end

      # Extract and cache a single file.
      # Reads the file, parses it with tree-sitter, extracts the code graph,
      # and saves to cache. Returns the extracted CodeGraph.
      # Safe to call from any fiber.
      def extract_and_cache_file(
        file_path : String,
        parser = Parser,
        cache_dir : String? = nil,
        repo_key : String? = nil,
        max_bytes : Int32? = nil,
      ) : CodeGraph?
        content = File.read(file_path)
        source_file = SourceFile.new(path: file_path, content: content)
        graph = extract_single_file(source_file, parser)

        if cache_dir && ((graph.files.try { |file_nodes| !file_nodes.empty? }) || !graph.defines.empty?)
          begin
            GraphCache.save_file_cache(
              [{path: file_path, content: content, graph: graph}],
              cache_dir,
              repo_key: repo_key,
              max_bytes: max_bytes || GraphCache.default_max_bytes_per_repo,
            )
          rescue ex
            STDERR.puts "[Chiasmus] cache write failed for #{file_path}: #{ex.message}"
          end
        end

        graph
      rescue ex
        STDERR.puts "[Chiasmus] extract error for #{file_path}: #{ex.message}"
        nil
      end

      # Pure extraction: returns a CodeGraph for a single file without touching any shared state.
      private def extract_single_file(
        file : SourceFile,
        parser,
      ) : CodeGraph
        started_at = Time.instant
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        contains = [] of ContainsFact
        file_nodes = [] of FileNode
        type_info = [] of FileTypeInfo

        lang = parser.language_for_file(file.path)
        return CodeGraph.new unless lang

        line_count = file.content.count('\n') + (file.content[-1]? != '\n' ? 1 : 0)
        token_estimate = (file.content.size / 3.5).ceil.to_i32
        fn = FileNode.new(
          path: file.path,
          language: lang,
          line_count: line_count,
          token_estimate: token_estimate,
        )
        file_nodes << fn

        if lang == "clojure"
          merge_adapter_graph(
            ClojureSourceExtractor.extract(file),
            defines, calls, imports, exports, contains,
            Set(String).new
          )
        else
          tree = parser.parse_source(file.content, file.path)
          return CodeGraph.new unless tree

          if lang.in?("typescript", "javascript", "tsx")
            type_info << TypeEnv.collect_type_info(tree.root_node, file.content, file.path)
          end

          adapter = AdapterRegistry.get_adapter(lang)
          if adapter
            merge_adapter_graph(
              adapter.extract(tree.root_node, file.content, file.path),
              defines, calls, imports, exports, contains,
              Set(String).new
            )
          else
            extract_with_walkers(
              lang, tree, file,
              defines, calls, imports, exports, contains,
              Set(String).new
            )
          end

          # TreeSitter::Node does not retain its owning Tree. Keep the tree live
          # through the complete adapter/walker traversal in optimized builds.
          tree.root_node
        end

        graph = CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports,
          exports: exports,
          contains: contains,
          files: file_nodes,
          type_info: type_info.empty? ? nil : type_info,
        )

        Tracing.info("chiasmus.graph.extract_single_file",
          path: shorten_path(file.path),
          language: lang,
          bytes: file.content.bytesize,
          lines: line_count,
          defines: defines.size,
          calls: calls.size,
          elapsed_ms: (Time.instant - started_at).total_milliseconds,
        )
        graph
      end

      private def shorten_path(path : String) : String
        parts = path.split('/')
        if parts.size > 4
          ".../#{parts[-4..].join("/")}"
        else
          path
        end
      end

      # Thread-safe merge of a single-file graph into the global accumulators.
      private def merge_graph_under_lock(
        graph : CodeGraph,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        file_nodes : Array(FileNode),
        type_info : Array(FileTypeInfo),
        call_set : Set(String),
      ) : Nil
        @@merge_mutex.synchronize do
          defines.concat(graph.defines)
          graph.calls.each do |call_fact|
            key = "#{call_fact.caller_qn || call_fact.caller}->#{call_fact.callee_qn || call_fact.callee}"
            next if call_set.includes?(key)
            call_set.add(key)
            calls << call_fact
          end
          imports.concat(graph.imports)
          exports.concat(graph.exports)
          contains.concat(graph.contains)
          graph.files.try &.each { |file_node| file_nodes << file_node }
          graph.type_info.try &.each { |type_inf| type_info << type_inf }
        end
      end

      private def merge_cached_graph(
        graph : CodeGraph,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        file_nodes : Array(FileNode),
        type_info : Array(FileTypeInfo),
        call_set : Set(String),
      ) : Nil
        defines.concat(graph.defines)
        graph.calls.each do |call_fact|
          key = "#{call_fact.caller_qn || call_fact.caller}->#{call_fact.callee_qn || call_fact.callee}"
          next if call_set.includes?(key)
          call_set.add(key)
          calls << call_fact
        end
        imports.concat(graph.imports)
        exports.concat(graph.exports)
        contains.concat(graph.contains)
        graph.files.try &.each { |file_node| file_nodes << file_node }
        graph.type_info.try &.each { |type_inf| type_info << type_inf }
      end

      private def merge_adapter_graph(
        partial : CodeGraph,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        defines.concat(partial.defines)
        partial.calls.each do |call_fact|
          key = "#{call_fact.caller_qn || call_fact.caller}->#{call_fact.callee_qn || call_fact.callee}"
          next if call_set.includes?(key)

          call_set.add(key)
          calls << call_fact
        end
        imports.concat(partial.imports)
        exports.concat(partial.exports)
        contains.concat(partial.contains)
      end

      private def extract_with_walkers(
        lang : String,
        tree : TreeSitter::Tree,
        file : SourceFile,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        scope_stack = [] of String
        case lang
        when "clojure"
          Walkers.walk_clojure(tree.root_node, file.content, file.path, defines, calls, imports, exports, call_set)
        when "python"
          Walkers.walk_python(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "go"
          Walkers.walk_go(tree.root_node, file.content, file.path, defines, calls, imports, exports, contains, call_set)
        when "crystal"
          Walkers.walk_crystal(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "rust"
          Walkers.walk_rust(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "java"
          Walkers.walk_java(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "csharp"
          Walkers.walk_csharp(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "cpp"
          Walkers.walk_cpp(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "bash"
          Walkers.walk_bash(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "c"
          Walkers.walk_c(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "dart"
          Walkers.walk_dart(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "kotlin"
          Walkers.walk_kotlin(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "perl"
          Walkers.walk_perl(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "php"
          Walkers.walk_php(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "proto"
          Walkers.walk_proto(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "scala"
          Walkers.walk_scala(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        else
          Walkers.walk_node(tree.root_node, file.content, file.path, lang, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
