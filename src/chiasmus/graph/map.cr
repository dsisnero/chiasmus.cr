# Ported from vendor/chiasmus/src/graph/map.ts
#
# Codebase map projections over a CodeGraph. Read-only view — doesn't parse,
# read files, or touch the cache. Builds summaries for LLM consumption.

require "./types"

module Chiasmus
  module Graph
    DEFAULT_MAX_EXPORTS =   8
    DEFAULT_DOC_LEN     = 160

    record SymbolEntry,
      name : String,
      kind : String,
      line : Int32,
      signature : String?,
      line_end : Int32 = 0

    record OverviewFile,
      path : String,
      language : String,
      lines : Int32?,
      tokens : Int32?,
      doc : String?,
      export_count : Int32,
      top_exports : Array(SymbolEntry)

    record OverviewSummary,
      files : Int32,
      languages : Array(String),
      tokens : Int32,
      definitions : Int32,
      exports : Int32

    record DirNode,
      name : String,
      dirs : Array(DirNode),
      files : Array(OverviewFile)

    record OverviewMap,
      kind : String,
      summary : OverviewSummary,
      root : DirNode

    record FileDetail,
      kind : String,
      path : String,
      language : String,
      lines : Int32?,
      tokens : Int32?,
      doc : String?,
      exports : Array(SymbolEntry),
      imports : Array(NamedTuple(name: String, source: String)),
      symbols : Array(SymbolEntry)

    record SymbolDetail,
      kind : String,
      name : String,
      defines : Array(NamedTuple(file: String, kind: String, line: Int32, line_end: Int32, signature: String?)),
      callers : Array(String),
      callees : Array(String)

    module CodebaseMap
      extend self

      def build_overview(graph : CodeGraph, max_exports : Int32 = DEFAULT_MAX_EXPORTS) : OverviewMap
        file_nodes = graph.files || [] of FileNode

        defines_by_file = Hash(String, Array(DefinesFact)).new { |hash, key| hash[key] = [] of DefinesFact }
        graph.defines.each { |definition| defines_by_file[definition.file] << definition }

        export_names = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
        graph.exports.each { |export_fact| export_names[export_fact.file] << export_fact.name }

        overview_files = [] of OverviewFile
        total_tokens = 0
        languages = Set(String).new

        file_nodes.each do |file_node|
          defines = defines_by_file[file_node.path]? || [] of DefinesFact
          exports = export_names[file_node.path]?
          export_count = exports.try(&.size) || 0
          top_exports = defines
            .select { |definition| exports.try(&.includes?(definition.name)) || false }
            .first(max_exports)
            .map { |definition| SymbolEntry.new(name: definition.name, kind: definition.kind.to_s.downcase, line: definition.span.start_line, line_end: definition.span.end_line, signature: definition.signature) }

          languages << file_node.language
          total_tokens += file_node.token_estimate || 0

          overview_files << OverviewFile.new(
            path: file_node.path,
            language: file_node.language,
            lines: file_node.line_count,
            tokens: file_node.token_estimate,
            doc: file_node.file_doc.try { |file_doc| file_doc[0, DEFAULT_DOC_LEN] },
            export_count: export_count,
            top_exports: top_exports,
          )
        end

        root = build_dir_tree(overview_files)

        OverviewMap.new(
          kind: "overview",
          summary: OverviewSummary.new(
            files: file_nodes.size,
            languages: languages.to_a.sort,
            tokens: total_tokens,
            definitions: graph.defines.size,
            exports: graph.exports.size,
          ),
          root: root,
        )
      end

      private def build_dir_tree(files : Array(OverviewFile)) : DirNode
        root = DirNode.new(name: "", dirs: [] of DirNode, files: [] of OverviewFile)

        files.each do |file|
          parts = file.path.split('/').reject(&.empty?)
          insert_into_tree(root, parts, file)
        end

        root
      end

      private def insert_into_tree(node : DirNode, path_parts : Array(String), file : OverviewFile, depth : Int32 = 0) : Nil
        if depth == path_parts.size - 1
          node.files << file
          return
        end

        dir_name = path_parts[depth]
        child = node.dirs.find { |dir_node| dir_node.name == dir_name }
        unless child
          child = DirNode.new(name: dir_name, dirs: [] of DirNode, files: [] of OverviewFile)
          node.dirs << child
        end

        insert_into_tree(child, path_parts, file, depth + 1)
      end

      def build_file_detail(graph : CodeGraph, path : String) : FileDetail?
        file_node = graph.files.try(&.find { |candidate| candidate.path == path })
        return nil unless file_node

        defines = graph.defines.select { |definition| definition.file == path }
        export_names = Set(String).new
        graph.exports.select { |export_fact| export_fact.file == path }.each { |export_fact| export_names << export_fact.name }
        imports = graph.imports.select { |import_fact| import_fact.file == path }

        FileDetail.new(
          kind: "file",
          path: path,
          language: file_node.language,
          lines: file_node.line_count,
          tokens: file_node.token_estimate,
          doc: file_node.file_doc.try { |file_doc| file_doc[0, DEFAULT_DOC_LEN] },
          exports: defines.select { |definition| export_names.includes?(definition.name) }
            .map { |definition| SymbolEntry.new(name: definition.name, kind: definition.kind.to_s.downcase, line: definition.span.start_line, line_end: definition.span.end_line, signature: definition.signature) },
          imports: imports.map { |import_fact| {name: import_fact.name, source: import_fact.source} },
          symbols: defines.map { |definition| SymbolEntry.new(name: definition.name, kind: definition.kind.to_s.downcase, line: definition.span.start_line, line_end: definition.span.end_line, signature: definition.signature) },
        )
      end

      def build_symbol_detail(graph : CodeGraph, name : String) : SymbolDetail?
        defs = graph.defines.select { |definition| definition.name == name }
        return nil if defs.empty?

        callers = graph.calls.select { |call_fact| call_fact.callee == name }.map(&.caller).uniq.sort
        callees = graph.calls.select { |call_fact| call_fact.caller == name }.map(&.callee).uniq.sort

        SymbolDetail.new(
          kind: "symbol",
          name: name,
          defines: defs.map { |definition| {file: definition.file, kind: definition.kind.to_s.downcase, line: definition.span.start_line, line_end: definition.span.end_line, signature: definition.signature} },
          callers: callers,
          callees: callees,
        )
      end

      def render_map(map : OverviewMap | FileDetail | SymbolDetail, format : String = "markdown") : String
        case format
        when "json"
          render_json(map)
        else
          render_markdown(map)
        end
      end

      private def render_json(map : OverviewMap | FileDetail | SymbolDetail) : String
        case map
        when OverviewMap
          return JSON.build do |json|
            json.object do
              json.field "kind", "overview"
              json.field "summary" do
                json.object do
                  json.field "files", map.summary.files
                  json.field "languages", map.summary.languages
                  json.field "tokens", map.summary.tokens
                  json.field "definitions", map.summary.definitions
                  json.field "exports", map.summary.exports
                end
              end
            end
          end
        when FileDetail
          return JSON.build do |json|
            json.object do
              json.field "kind", "file"
              json.field "path", map.path
              json.field "language", map.language
              json.field "symbols" do
                json.array do
                  map.symbols.each do |symbol_entry|
                    json.object do
                      json.field "name", symbol_entry.name
                      json.field "kind", symbol_entry.kind
                      json.field "line", symbol_entry.line
                      if symbol_entry.line_end > 0
                        json.field "line_end", symbol_entry.line_end
                      end
                      if sig = symbol_entry.signature
                        json.field "signature", sig
                      end
                    end
                  end
                end
              end
            end
          end
        else # SymbolDetail
          return JSON.build do |json|
            json.object do
              json.field "kind", "symbol"
              json.field "name", map.name
              json.field "defines" do
                json.array do
                  map.defines.each do |definition|
                    json.object do
                      json.field "file", definition[:file]
                      json.field "kind", definition[:kind]
                      json.field "line", definition[:line]
                      if definition[:line_end] > 0
                        json.field "line_end", definition[:line_end]
                      end
                      if sig = definition[:signature]
                        json.field "signature", sig
                      end
                    end
                  end
                end
              end
              json.field "callers", map.callers
              json.field "callees", map.callees
            end
          end
        end
      end

      private def render_markdown(map : OverviewMap | FileDetail | SymbolDetail) : String
        case map
        when OverviewMap
          lines = ["# Codebase Overview", "", "**Files**: #{map.summary.files} | **Definitions**: #{map.summary.definitions} | **Exports**: #{map.summary.exports}"]
          map.root.dirs.each { |dir_node| render_dir_tree(dir_node, lines, 2) }
          lines.join("
")
        when FileDetail
          lines = ["## #{map.path}", "", "**Language**: #{map.language}", "**Symbols**: #{map.symbols.size}"]
          map.symbols.each { |symbol_entry| lines << "- `#{symbol_entry.name}` (#{symbol_entry.kind}) line #{symbol_entry.line}#{symbol_entry.line_end > 0 ? "-#{symbol_entry.line_end}" : ""}#{symbol_entry.signature ? " — #{symbol_entry.signature}" : ""}" }
          lines.join("
")
        when SymbolDetail
          defined_in = map.defines.map { |definition|
            loc = "#{definition[:file]}:#{definition[:line]}"
            loc += "-#{definition[:line_end]}" if definition[:line_end] > 0
            loc
          }.join(", ")
          lines = ["## #{map.name}", "", "**Defined in**: #{defined_in}"]
          unless map.callers.empty?
            lines << "**Callers**: #{map.callers.join(", ")}"
          end
          unless map.callees.empty?
            lines << "**Callees**: #{map.callees.join(", ")}"
          end
          lines.join("
")
        else
          ""
        end
      end

      private def render_dir_tree(node : DirNode, lines : Array(String), depth : Int32) : Nil
        prefix = "  " * depth
        lines << "#{prefix}- **#{node.name}/**"
        node.dirs.each { |dir_node| render_dir_tree(dir_node, lines, depth + 1) }
        node.files.each { |overview_file| lines << "#{prefix}  - #{File.basename(overview_file.path)} (#{overview_file.language}, #{overview_file.export_count} exports)" }
      end

      def glob_match(path : String, pattern : String) : Bool
        return true if pattern == "**"
        return path == pattern unless pattern.includes?('*')

        if pattern.starts_with?("**/")
          suffix = pattern[3..]
          return true if suffix == "*"
          # **/suffix: suffix is a glob like *.ts
          if suffix.starts_with?("*.")
            ext = suffix[1..] # ".ts"
            return path.ends_with?(ext)
          end
          return path.ends_with?("/#{suffix}") || path == suffix
        end

        # *.ext — match files with extension
        if pattern.starts_with?("*.") && path.ends_with?(pattern[1..])
          return true
        end

        path == pattern
      end
    end
  end
end
