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
      signature : String?

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
      defines : Array(NamedTuple(file: String, kind: String, line: Int32, signature: String?)),
      callers : Array(String),
      callees : Array(String)

    module CodebaseMap
      extend self

      def build_overview(graph : CodeGraph, max_exports : Int32 = DEFAULT_MAX_EXPORTS) : OverviewMap
        file_nodes = graph.files || [] of FileNode

        defines_by_file = Hash(String, Array(DefinesFact)).new { |h, k| h[k] = [] of DefinesFact }
        graph.defines.each { |d| defines_by_file[d.file] << d }

        export_names = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
        graph.exports.each { |e| export_names[e.file] << e.name }

        overview_files = [] of OverviewFile
        total_tokens = 0
        languages = Set(String).new

        file_nodes.each do |fn|
          defines = defines_by_file[fn.path]? || [] of DefinesFact
          exports = export_names[fn.path]?
          export_count = exports.try(&.size) || 0
          top_exports = defines
            .select { |d| exports.try(&.includes?(d.name)) || false }
            .first(max_exports)
            .map { |d| SymbolEntry.new(name: d.name, kind: d.kind.to_s.downcase, line: d.line, signature: d.signature) }

          languages << fn.language
          total_tokens += fn.token_estimate || 0

          overview_files << OverviewFile.new(
            path: fn.path,
            language: fn.language,
            lines: fn.line_count,
            tokens: fn.token_estimate,
            doc: fn.file_doc.try { |d| d[0, DEFAULT_DOC_LEN] },
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
        child = node.dirs.find { |d| d.name == dir_name }
        unless child
          child = DirNode.new(name: dir_name, dirs: [] of DirNode, files: [] of OverviewFile)
          node.dirs << child
        end

        insert_into_tree(child, path_parts, file, depth + 1)
      end

      def build_file_detail(graph : CodeGraph, path : String) : FileDetail?
        fn = graph.files.try(&.find { |f| f.path == path })
        return nil unless fn

        defines = graph.defines.select { |d| d.file == path }
        export_names = Set(String).new
        graph.exports.select { |e| e.file == path }.each { |e| export_names << e.name }
        imports = graph.imports.select { |i| i.file == path }

        FileDetail.new(
          kind: "file",
          path: path,
          language: fn.language,
          lines: fn.line_count,
          tokens: fn.token_estimate,
          doc: fn.file_doc.try { |d| d[0, DEFAULT_DOC_LEN] },
          exports: defines.select { |d| export_names.includes?(d.name) }
            .map { |d| SymbolEntry.new(name: d.name, kind: d.kind.to_s.downcase, line: d.line, signature: d.signature) },
          imports: imports.map { |i| {name: i.name, source: i.source} },
          symbols: defines.map { |d| SymbolEntry.new(name: d.name, kind: d.kind.to_s.downcase, line: d.line, signature: d.signature) },
        )
      end

      def build_symbol_detail(graph : CodeGraph, name : String) : SymbolDetail?
        defs = graph.defines.select { |d| d.name == name }
        return nil if defs.empty?

        callers = graph.calls.select { |c| c.callee == name }.map(&.caller).uniq.sort
        callees = graph.calls.select { |c| c.caller == name }.map(&.callee).uniq.sort

        SymbolDetail.new(
          kind: "symbol",
          name: name,
          defines: defs.map { |d| {file: d.file, kind: d.kind.to_s.downcase, line: d.line, signature: d.signature} },
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
                  map.symbols.each do |s|
                    json.object do
                      json.field "name", s.name
                      json.field "kind", s.kind
                      json.field "line", s.line
                      if sig = s.signature
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
          map.root.dirs.each { |d| render_dir_tree(d, lines, 2) }
          lines.join("
")
        when FileDetail
          lines = ["## #{map.path}", "", "**Language**: #{map.language}", "**Symbols**: #{map.symbols.size}"]
          map.symbols.each { |s| lines << "- `#{s.name}` (#{s.kind}) line #{s.line}#{s.signature ? " — #{s.signature}" : ""}" }
          lines.join("
")
        when SymbolDetail
          lines = ["## #{map.name}", "", "**Defined in**: #{map.defines.map(&.[:file]).join(", ")}"]
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
        node.dirs.each { |d| render_dir_tree(d, lines, depth + 1) }
        node.files.each { |f| lines << "#{prefix}  - #{File.basename(f.path)} (#{f.language}, #{f.export_count} exports)" }
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
