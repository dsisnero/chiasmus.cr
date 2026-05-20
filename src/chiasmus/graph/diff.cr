# Ported from vendor/chiasmus/src/graph/diff.ts
#
# Graph diff: set difference on nodes + (src,tgt) edge keys.
# Compares two CodeGraphs and reports added/removed nodes, edges,
# imports, exports, and hyperedges.

require "./types"

module Chiasmus
  module Graph
    record GraphDiffEdge, source : String, target : String

    record GraphDiffResult,
      added_nodes : Array(String),
      removed_nodes : Array(String),
      added_edges : Array(GraphDiffEdge),
      removed_edges : Array(GraphDiffEdge),
      added_imports : Array(ImportsFact),
      removed_imports : Array(ImportsFact),
      added_exports : Array(ExportsFact),
      removed_exports : Array(ExportsFact),
      summary : String

    module GraphDiffer
      extend self

      private def collect_nodes(graph : CodeGraph) : Set(String)
        nodes = Set(String).new
        graph.defines.each { |d| nodes << d.name }
        graph.calls.each do |c|
          nodes << c.caller
          nodes << c.callee
        end
        nodes
      end

      private def edge_key(src : String, tgt : String) : String
        "#{src}\u0000#{tgt}"
      end

      private def import_key(i : ImportsFact) : String
        "#{i.file}\u0000#{i.name}\u0000#{i.source}"
      end

      private def export_key(e : ExportsFact) : String
        "#{e.file}\u0000#{e.name}"
      end

      private def collect_edge_keys(graph : CodeGraph) : Set(String)
        set = Set(String).new
        graph.calls.each { |c| set << edge_key(c.caller, c.callee) }
        set
      end

      private def diff_by_key(before : Array(T), after : Array(T), key_fn : T -> String) : {Array(T), Array(T)} forall T
        before_map = Hash(String, T).new
        before.each { |item| before_map[key_fn.call(item)] = item }
        after_map = Hash(String, T).new
        after.each { |item| after_map[key_fn.call(item)] = item }

        added = [] of T
        removed = [] of T
        after_map.each { |k, v| added << v unless before_map.has_key?(k) }
        before_map.each { |k, v| removed << v unless after_map.has_key?(k) }
        {added, removed}
      end

      private def pluralize(n : Int32, singular : String) : String
        "#{n} #{singular}#{n == 1 ? "" : "s"}"
      end

      def diff(before : CodeGraph, after : CodeGraph) : GraphDiffResult
        before_nodes = collect_nodes(before)
        after_nodes = collect_nodes(after)

        added_nodes = after_nodes.reject { |n| before_nodes.includes?(n) }.to_a.sort!
        removed_nodes = before_nodes.reject { |n| after_nodes.includes?(n) }.to_a.sort!

        before_edges = collect_edge_keys(before)
        after_edges = collect_edge_keys(after)

        added_edges = [] of GraphDiffEdge
        removed_edges = [] of GraphDiffEdge

        after_edges.each do |k|
          next if before_edges.includes?(k)
          parts = k.split('\u0000')
          added_edges << GraphDiffEdge.new(source: parts[0], target: parts[1]) if parts.size >= 2
        end

        before_edges.each do |k|
          next if after_edges.includes?(k)
          parts = k.split('\u0000')
          removed_edges << GraphDiffEdge.new(source: parts[0], target: parts[1]) if parts.size >= 2
        end

        added_edges.sort_by! { |e| {e.source, e.target} }
        removed_edges.sort_by! { |e| {e.source, e.target} }

        added_imports, removed_imports = diff_by_key(before.imports, after.imports, ->import_key(ImportsFact))
        added_exports, removed_exports = diff_by_key(before.exports, after.exports, ->export_key(ExportsFact))

        parts = [] of String
        parts << pluralize(added_nodes.size, "new node") unless added_nodes.empty?
        parts << pluralize(added_edges.size, "new edge") unless added_edges.empty?
        parts << pluralize(added_imports.size, "new import") unless added_imports.empty?
        parts << pluralize(added_exports.size, "new export") unless added_exports.empty?
        parts << "#{pluralize(removed_nodes.size, "node")} removed" unless removed_nodes.empty?
        parts << "#{pluralize(removed_edges.size, "edge")} removed" unless removed_edges.empty?
        parts << "#{pluralize(removed_imports.size, "import")} removed" unless removed_imports.empty?
        parts << "#{pluralize(removed_exports.size, "export")} removed" unless removed_exports.empty?
        summary = parts.empty? ? "no changes" : parts.join(", ")

        GraphDiffResult.new(
          added_nodes: added_nodes,
          removed_nodes: removed_nodes,
          added_edges: added_edges,
          removed_edges: removed_edges,
          added_imports: added_imports,
          removed_imports: removed_imports,
          added_exports: added_exports,
          removed_exports: removed_exports,
          summary: summary,
        )
      end
    end
  end
end
