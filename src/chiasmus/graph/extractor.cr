require "./parser"
require "./walkers"
require "./adapter_registry"
require "./clojure_source_extractor"
require "./type_env"
require "./resolve_calls"
require "./cache"

module Chiasmus
  module Graph
    record SourceFile, path : String, content : String

    module Extractor
      extend self

      def extract_graph(files : Array(SourceFile), parser = Parser, cache_dir : String? = nil) : CodeGraph
        # Determine files to extract (split cached vs fresh)
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

        # Extract fresh files
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        contains = [] of ContainsFact
        type_info = [] of FileTypeInfo
        file_nodes = [] of FileNode
        call_set = Set(String).new

        fresh_graphs = [] of {path: String, content: String, graph: CodeGraph}

        to_extract.each do |file|
          fresh_graph = extract_per_file_graph(file, parser, file_nodes, defines, calls, imports, exports, contains, type_info, call_set)
          fresh_graphs << {path: file.path, content: file.content, graph: fresh_graph}
        end

        # Save fresh graphs to cache
        if cache_dir && !fresh_graphs.empty?
          GraphCache.save_file_cache(fresh_graphs, cache_dir)
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

      private def extract_per_file_graph(
        file : SourceFile,
        parser,
        file_nodes : Array(FileNode),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        type_info : Array(FileTypeInfo),
        call_set : Set(String),
      ) : CodeGraph
        per_defines = [] of DefinesFact
        per_calls = [] of CallsFact
        per_imports = [] of ImportsFact
        per_exports = [] of ExportsFact
        per_contains = [] of ContainsFact
        per_file_nodes = [] of FileNode
        per_type_info = [] of FileTypeInfo

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
        per_file_nodes << fn
        file_nodes.concat(per_file_nodes)

        if lang == "clojure"
          merge_adapter_graph(
            ClojureSourceExtractor.extract(file),
            per_defines,
            per_calls,
            per_imports,
            per_exports,
            per_contains,
            Set(String).new
          )
        else
          tree = parser.parse_source(file.content, file.path)
          return CodeGraph.new unless tree

          if lang.in?("typescript", "javascript", "tsx")
            per_type_info << TypeEnv.collect_type_info(tree.root_node, file.content, file.path)
          end

          adapter = AdapterRegistry.get_adapter(lang)
          if adapter
            merge_adapter_graph(
              adapter.extract(tree.root_node, file.content, file.path),
              per_defines,
              per_calls,
              per_imports,
              per_exports,
              per_contains,
              Set(String).new
            )
          else
            extract_with_walkers(
              lang, tree, file,
              per_defines, per_calls, per_imports, per_exports, per_contains,
              Set(String).new
            )
          end
        end

        # Merge per-file results into global accumulators
        defines.concat(per_defines)
        per_calls.each do |call_fact|
          key = "#{call_fact.caller}->#{call_fact.callee}"
          next if call_set.includes?(key)
          call_set.add(key)
          calls << call_fact
        end
        imports.concat(per_imports)
        exports.concat(per_exports)
        contains.concat(per_contains)
        type_info.concat(per_type_info)

        CodeGraph.new(
          defines: per_defines,
          calls: per_calls,
          imports: per_imports,
          exports: per_exports,
          contains: per_contains,
          files: per_file_nodes,
          type_info: per_type_info.empty? ? nil : per_type_info,
        )
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
        else
          Walkers.walk_node(tree.root_node, file.content, file.path, lang, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
