require "./parser"
require "./walkers"
require "./adapter_registry"
require "./clojure_source_extractor"
require "./type_env"
require "./resolve_calls"
require "./cache"
require "./parallel_io"

module Chiasmus
  module Graph
    module Extractor
      extend self

      @@merge_mutex = Mutex.new

      def extract_graph(files : Array(SourceFile), parser = Parser, cache_dir : String? = nil, max_bytes : Int32? = nil) : CodeGraph
        to_extract = files
        cached = [] of NamedTuple(path: String, graph: CodeGraph)

        if cache_dir
          check_result = GraphCache.check_file_cache(
            files.map { |file_info| {path: file_info.path, content: file_info.content} },
            cache_dir
          )
          cached = check_result[:hits]
          to_extract = check_result[:misses].map { |miss| SourceFile.new(path: miss[:path], content: miss[:content]) }
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

        # Process files with bounded concurrency
        max_concurrent = System.cpu_count
        semaphore = Channel(Nil).new(max_concurrent)
        results = Channel(CodeGraph).new(to_extract.size)

        to_extract.each do |file|
          spawn do
            semaphore.send(nil)
            begin
              fresh_graph = extract_single_file(file, parser)
              results.send(fresh_graph)
            rescue ex
              results.send(CodeGraph.new)
            ensure
              semaphore.receive
            end
          end
        end

        # Collect results and merge under mutex
        to_extract.size.times do
          fresh_graph = results.receive
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

        # Save fresh graphs to cache asynchronously (fire-and-forget)
        if cache_dir && !fresh_graphs.empty?
          dir = cache_dir
          limit = max_bytes || GraphCache.default_max_bytes_per_repo
          spawn do
            GraphCache.save_file_cache(fresh_graphs, dir, max_bytes: limit)
          end
        end

        # Merge cached graphs
        cached.each do |entry|
          merge_cached_graph(entry[:graph], defines, calls, imports, exports, contains, file_nodes, type_info, call_set)
        end

        CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports,
          exports: exports,
          contains: contains,
          files: file_nodes.empty? ? nil : file_nodes,
          type_info: type_info.empty? ? nil : type_info
        )
      end

      # Pure extraction: returns a CodeGraph for a single file without touching any shared state.
      private def extract_single_file(
        file : SourceFile,
        parser,
      ) : CodeGraph
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
        end

        CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports,
          exports: exports,
          contains: contains,
          files: file_nodes,
          type_info: type_info.empty? ? nil : type_info,
        )
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
            key = "#{call_fact.caller}->#{call_fact.callee}"
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
          key = "#{call_fact.caller}->#{call_fact.callee}"
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
          key = "#{call_fact.caller}->#{call_fact.callee}"
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
