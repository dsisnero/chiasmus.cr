require "./types"
require "./names"

module Chiasmus
  module Graph
    module IR
      record SymbolNode,
        id : String,
        name : String,
        qualified_name : String,
        owner_name : String?,
        kind : SymbolKind,
        file : String,
        line : Int32,
        end_line : Int32 = 0,
        signature : String? = nil do
        def simple_name : String
          name
        end
      end

      record FileNode,
        path : String,
        language : String,
        line_count : Int32? = nil,
        token_estimate : Int32? = nil,
        file_doc : String? = nil

      record CallEdge,
        caller : String,
        callee : String,
        callee_qn : String? = nil

      record ImportEdge,
        file : String,
        name : String,
        source : String

      record ExportEdge,
        file : String,
        name : String

      record ContainsEdge,
        parent : String,
        child : String

      record ScopedContainsEdge,
        file : String,
        parent : String,
        child : String

      record ScopedCallEdge,
        file : String,
        caller : String,
        callee : String,
        callee_qn : String? = nil

      record SemanticGraph,
        files : Array(FileNode) = [] of FileNode,
        symbols : Array(SymbolNode) = [] of SymbolNode,
        calls : Array(CallEdge) = [] of CallEdge,
        imports : Array(ImportEdge) = [] of ImportEdge,
        exports : Array(ExportEdge) = [] of ExportEdge,
        contains : Array(ContainsEdge) = [] of ContainsEdge,
        type_info : Array(FileTypeInfo)? = nil do
        def symbol_ids : Array(String)
          symbols.map(&.id)
        end

        def find_symbol(id : String) : SymbolNode?
          symbols.find { |symbol| symbol.id == id }
        end
      end

      abstract class Refiner
        abstract def refine(graph : SemanticGraph) : SemanticGraph
      end

      class ScopedSymbolIndex
        def initialize(symbols : Array(SymbolNode))
          @by_name = Hash(String, Array(SymbolNode)).new { |hash, key| hash[key] = [] of SymbolNode }
          @by_file_and_name = Hash(Tuple(String, String), Array(SymbolNode)).new { |hash, key| hash[key] = [] of SymbolNode }

          symbols.each do |symbol|
            @by_name[symbol.qualified_name] << symbol
            @by_file_and_name[{symbol.file, symbol.qualified_name}] << symbol
          end
        end

        def symbols_named(qualified_name : String) : Array(SymbolNode)
          @by_name[qualified_name]? || [] of SymbolNode
        end

        def symbols_in_file(file : String, qualified_name : String) : Array(SymbolNode)
          @by_file_and_name[{file, qualified_name}]? || [] of SymbolNode
        end

        def unique_symbol_in_file(
          qualified_name : String,
          file : String,
          container_only : Bool = false,
          ownerless_only : Bool = false,
        ) : SymbolNode?
          matches = symbols_in_file(file, qualified_name).select do |symbol|
            next false if container_only && !container_kind?(symbol.kind)
            next false if ownerless_only && symbol.owner_name
            true
          end

          return nil unless matches.size == 1
          matches.first
        end

        private def container_kind?(kind : SymbolKind) : Bool
          kind.in?(SymbolKind::Class, SymbolKind::Interface, SymbolKind::Module, SymbolKind::Type)
        end
      end

      module NormalizationSupport
        private def normalize_symbol(symbol : SymbolNode) : SymbolNode
          qualified_name = symbol.qualified_name

          SymbolNode.new(
            id: Lowering.symbol_id(symbol.file, symbol.kind, qualified_name),
            name: Lowering.simple_name(qualified_name),
            qualified_name: qualified_name,
            owner_name: Lowering.owner_name(qualified_name),
            kind: symbol.kind,
            file: symbol.file,
            line: symbol.line,
            end_line: symbol.end_line,
            signature: symbol.signature,
          )
        end

        private def qualify_contained_symbols(
          symbols : Array(SymbolNode),
          contains : Array(ScopedContainsEdge),
        ) : {Array(SymbolNode), Array(ScopedContainsEdge)}
          current_symbols = symbols
          current_contains = contains

          loop do
            renames = direct_containment_renames(current_symbols, current_contains)
            break if renames.empty?

            updated_symbols = rewrite_symbols(current_symbols, renames)
            break if updated_symbols == current_symbols

            current_symbols = updated_symbols
            current_contains = rewrite_scoped_contains(current_contains, renames)
          end

          {current_symbols, current_contains}
        end

        private def direct_containment_renames(
          symbols : Array(SymbolNode),
          contains : Array(ScopedContainsEdge),
        ) : Hash(Tuple(String, String), String)
          index = ScopedSymbolIndex.new(symbols)
          renames = Hash(Tuple(String, String), String).new

          contains.each do |edge|
            parent = index.unique_symbol_in_file(edge.parent, file: edge.file, container_only: true)
            next unless parent

            child = index.unique_symbol_in_file(edge.child, file: edge.file)
            next unless child

            qualified_name = Names.merge_containment_names(parent.qualified_name, child.qualified_name)
            next if qualified_name == child.qualified_name
            renames[{child.file, child.qualified_name}] = qualified_name
          end

          renames
        end

        private def rewrite_symbols(
          symbols : Array(SymbolNode),
          renames : Hash(Tuple(String, String), String),
        ) : Array(SymbolNode)
          symbols.map do |symbol|
            qualified_name = renames[{symbol.file, symbol.qualified_name}]? || symbol.qualified_name
            next symbol if qualified_name == symbol.qualified_name

            SymbolNode.new(
              id: Lowering.symbol_id(symbol.file, symbol.kind, qualified_name),
              name: Lowering.simple_name(qualified_name),
              qualified_name: qualified_name,
              owner_name: Lowering.owner_name(qualified_name),
              kind: symbol.kind,
              file: symbol.file,
              line: symbol.line,
              end_line: symbol.end_line,
              signature: symbol.signature,
            )
          end
        end

        private def container_kind?(kind : SymbolKind) : Bool
          kind.in?(SymbolKind::Class, SymbolKind::Interface, SymbolKind::Module, SymbolKind::Type)
        end

        private def rename_maps(
          original_symbols : Array(SymbolNode),
          renamed_symbols : Array(SymbolNode),
        ) : {Hash(Tuple(String, String), String), Hash(String, String)}
          by_file = Hash(Tuple(String, String), String).new
          global_candidates = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }

          original_symbols.each_with_index do |symbol, index|
            renamed = renamed_symbols[index]
            next if renamed.qualified_name == symbol.qualified_name

            by_file[{symbol.file, symbol.qualified_name}] = renamed.qualified_name
            global_candidates[symbol.qualified_name] << renamed.qualified_name
          end

          global = Hash(String, String).new
          global_candidates.each do |old_name, new_names|
            next unless new_names.size == 1
            global[old_name] = new_names.first
          end

          {by_file, global}
        end

        private def rewrite_scoped_contains(
          contains : Array(ScopedContainsEdge),
          renames : Hash(Tuple(String, String), String),
        ) : Array(ScopedContainsEdge)
          contains.map do |edge|
            ScopedContainsEdge.new(
              edge.file,
              renames[{edge.file, edge.parent}]? || edge.parent,
              renames[{edge.file, edge.child}]? || edge.child,
            )
          end
        end

        private def lift_scoped_contains(contains : Array(ScopedContainsEdge)) : Array(ContainsEdge)
          contains.map { |edge| ContainsEdge.new(edge.parent, edge.child) }
        end

        private def rewrite_scoped_calls(
          calls : Array(ScopedCallEdge),
          renames : Hash(Tuple(String, String), String),
        ) : Array(ScopedCallEdge)
          calls.map do |edge|
            ScopedCallEdge.new(
              edge.file,
              renames[{edge.file, edge.caller}]? || edge.caller,
              renames[{edge.file, edge.callee}]? || edge.callee,
              edge.callee_qn.try { |name| renames[{edge.file, name}]? || name },
            )
          end
        end

        private def lift_scoped_calls(calls : Array(ScopedCallEdge)) : Array(CallEdge)
          calls.map { |edge| CallEdge.new(edge.caller, edge.callee, edge.callee_qn) }
        end

        private def rewrite_calls(
          calls : Array(CallEdge),
          rename_by_file : Hash(Tuple(String, String), String),
          rename_global : Hash(String, String),
        ) : Array(CallEdge)
          calls.map do |edge|
            CallEdge.new(
              rewrite_name(edge.caller, rename_by_file, rename_global),
              rewrite_name(edge.callee, rename_by_file, rename_global),
              edge.callee_qn.try { |name| rewrite_name(name, rename_by_file, rename_global) },
            )
          end
        end

        private def rewrite_exports(
          exports : Array(ExportEdge),
          rename_by_file : Hash(Tuple(String, String), String),
          rename_global : Hash(String, String),
        ) : Array(ExportEdge)
          exports.map do |edge|
            ExportEdge.new(edge.file, rewrite_name(edge.name, rename_by_file, rename_global, edge.file))
          end
        end

        private def rewrite_contains(
          contains : Array(ContainsEdge),
          rename_by_file : Hash(Tuple(String, String), String),
          rename_global : Hash(String, String),
        ) : Array(ContainsEdge)
          contains.map do |edge|
            ContainsEdge.new(
              rewrite_name(edge.parent, rename_by_file, rename_global),
              rewrite_name(edge.child, rename_by_file, rename_global),
            )
          end
        end

        private def rewrite_name(
          name : String,
          rename_by_file : Hash(Tuple(String, String), String),
          rename_global : Hash(String, String),
          file : String? = nil,
        ) : String
          if file
            renamed = rename_by_file[{file, name}]?
            return renamed if renamed
          end

          rename_global[name]? || name
        end

        private def scope_contains(symbols : Array(SymbolNode), contains : Array(ContainsEdge)) : Array(ScopedContainsEdge)
          index = ScopedSymbolIndex.new(symbols)
          contains.flat_map { |edge| scoped_contains_candidates(index, edge) }
        end

        private def unresolved_contains(symbols : Array(SymbolNode), contains : Array(ContainsEdge)) : Array(ContainsEdge)
          index = ScopedSymbolIndex.new(symbols)
          contains.select { |edge| scoped_contains_candidates(index, edge).empty? }
        end

        private def scoped_contains_candidates(index : ScopedSymbolIndex, edge : ContainsEdge) : Array(ScopedContainsEdge)
          parents = index.symbols_named(edge.parent).select { |symbol| container_kind?(symbol.kind) }

          candidates = [] of ScopedContainsEdge
          parents.each do |parent|
            children = index.symbols_in_file(parent.file, edge.child)
            next unless children.size == 1

            candidates << ScopedContainsEdge.new(parent.file, parent.qualified_name, children.first.qualified_name)
          end

          deduplicate(candidates) do |candidate|
            "#{candidate.file}\u0000#{candidate.parent}\u0000#{candidate.child}"
          end
        end

        private def scope_calls(symbols : Array(SymbolNode), calls : Array(CallEdge)) : Array(ScopedCallEdge)
          index = ScopedSymbolIndex.new(symbols)
          calls.flat_map { |edge| scoped_call_candidates(index, edge) }
        end

        private def unresolved_calls(symbols : Array(SymbolNode), calls : Array(CallEdge)) : Array(CallEdge)
          index = ScopedSymbolIndex.new(symbols)
          calls.select { |edge| scoped_call_candidates(index, edge).empty? }
        end

        private def scoped_call_candidates(index : ScopedSymbolIndex, edge : CallEdge) : Array(ScopedCallEdge)
          callers = index.symbols_named(edge.caller)

          candidates = [] of ScopedCallEdge
          callers.each do |caller|
            callees = index.symbols_in_file(caller.file, edge.callee)
            next unless callees.size == 1

            callee_qn = edge.callee_qn
            if callee_qn
              next unless callees.first.qualified_name == callee_qn
            end

            candidates << ScopedCallEdge.new(caller.file, caller.qualified_name, callees.first.qualified_name, callee_qn)
          end

          deduplicate(candidates) do |candidate|
            "#{candidate.file}\u0000#{candidate.caller}\u0000#{candidate.callee}\u0000#{candidate.callee_qn || ""}"
          end
        end

        private def deduplicate(items : Array(T), & : T -> String) : Array(T) forall T
          seen = Set(String).new
          items.select { |item| seen.add?(yield item) }
        end
      end

      class SymbolCanonicalizationRefiner < Refiner
        include NormalizationSupport

        def refine(graph : SemanticGraph) : SemanticGraph
          SemanticGraph.new(
            files: graph.files,
            symbols: graph.symbols.map { |symbol| normalize_symbol(symbol) },
            calls: graph.calls,
            imports: graph.imports,
            exports: graph.exports,
            contains: graph.contains,
            type_info: graph.type_info,
          )
        end
      end

      class ContainedSymbolQualificationRefiner < Refiner
        include NormalizationSupport

        def refine(graph : SemanticGraph) : SemanticGraph
          scoped_calls = scope_calls(graph.symbols, graph.calls)
          unresolved_call_edges = unresolved_calls(graph.symbols, graph.calls)
          scoped_contains = scope_contains(graph.symbols, graph.contains)
          unresolved_containment = unresolved_contains(graph.symbols, graph.contains)
          qualified_symbols, qualified_scoped_contains = qualify_contained_symbols(graph.symbols, scoped_contains)
          rename_by_file, rename_global = rename_maps(graph.symbols, qualified_symbols)

          SemanticGraph.new(
            files: graph.files,
            symbols: qualified_symbols,
            calls: lift_scoped_calls(rewrite_scoped_calls(scoped_calls, rename_by_file)) +
                   rewrite_calls(unresolved_call_edges, rename_by_file, rename_global),
            imports: graph.imports,
            exports: rewrite_exports(graph.exports, rename_by_file, rename_global),
            contains: lift_scoped_contains(qualified_scoped_contains) +
                      rewrite_contains(unresolved_containment, rename_by_file, rename_global)
                        .reject { |edge| edge.parent == edge.child },
            type_info: graph.type_info,
          )
        end
      end

      class StructuralCleanupRefiner < Refiner
        include NormalizationSupport

        def refine(graph : SemanticGraph) : SemanticGraph
          deduplicated_symbols = deduplicate(graph.symbols, &.id)
          normalized_files = deduplicate(graph.files, &.path)
          normalized_calls = deduplicate(graph.calls) do |edge|
            "#{edge.caller}\u0000#{edge.callee}\u0000#{edge.callee_qn || ""}"
          end
          normalized_calls.sort_by! { |edge| {edge.caller, edge.callee, edge.callee_qn || ""} }
          normalized_imports = deduplicate(graph.imports) { |edge| "#{edge.file}\u0000#{edge.name}\u0000#{edge.source}" }
          normalized_exports = deduplicate(graph.exports) { |edge| "#{edge.file}\u0000#{edge.name}" }
          normalized_contains = deduplicate(graph.contains.reject { |edge| edge.parent == edge.child }) do |edge|
            "#{edge.parent}\u0000#{edge.child}"
          end
          normalized_contains.sort_by! { |edge| {edge.parent, edge.child} }

          SemanticGraph.new(
            files: normalized_files,
            symbols: deduplicated_symbols,
            calls: normalized_calls,
            imports: normalized_imports,
            exports: normalized_exports,
            contains: normalized_contains,
            type_info: graph.type_info,
          )
        end
      end

      class CommonNormalizationRefiner < Refiner
        def refine(graph : SemanticGraph) : SemanticGraph
          graph = SymbolCanonicalizationRefiner.new.refine(graph)
          graph = ContainedSymbolQualificationRefiner.new.refine(graph)
          StructuralCleanupRefiner.new.refine(graph)
        end
      end

      class Pipeline
        def initialize(@refiners : Array(Refiner))
        end

        def refine(graph : SemanticGraph) : SemanticGraph
          @refiners.reduce(graph) { |current, refiner| refiner.refine(current) }
        end

        def refine_async(graph : SemanticGraph) : Channel(SemanticGraph)
          channel = Channel(SemanticGraph).new(1)

          spawn do
            begin
              channel.send(refine(graph))
            ensure
              channel.close
            end
          end

          channel
        end
      end

      extend self

      def default_pipeline : Pipeline
        Pipeline.new([
          SymbolCanonicalizationRefiner.new,
          ContainedSymbolQualificationRefiner.new,
          StructuralCleanupRefiner.new,
        ] of Refiner)
      end

      def normalize(graph : CodeGraph) : SemanticGraph
        normalize(Lowering.from_code_graph(graph))
      end

      def normalize(graph : SemanticGraph) : SemanticGraph
        default_pipeline.refine(graph)
      end

      module Lowering
        extend self

        def from_code_graph(graph : CodeGraph) : SemanticGraph
          SemanticGraph.new(
            files: lower_files(graph.files),
            symbols: graph.defines.map { |fact| lower_symbol(fact) },
            calls: graph.calls.map { |fact| CallEdge.new(fact.caller, fact.callee, fact.callee_qn) },
            imports: graph.imports.map { |fact| ImportEdge.new(fact.file, fact.name, fact.source) },
            exports: graph.exports.map { |fact| ExportEdge.new(fact.file, fact.name) },
            contains: graph.contains.map { |fact| ContainsEdge.new(fact.parent, fact.child) },
            type_info: graph.type_info,
          )
        end

        def to_code_graph(graph : SemanticGraph) : CodeGraph
          CodeGraph.new(
            defines: graph.symbols.map { |symbol| lift_symbol(symbol) },
            calls: graph.calls.map { |edge| CallsFact.new(edge.caller, edge.callee, edge.callee_qn) },
            imports: graph.imports.map { |edge| ImportsFact.new(edge.file, edge.name, edge.source) },
            exports: graph.exports.map { |edge| ExportsFact.new(edge.file, edge.name) },
            contains: graph.contains.map { |edge| ContainsFact.new(edge.parent, edge.child) },
            files: lift_files(graph.files),
            type_info: graph.type_info,
          )
        end

        def symbol_id(file : String, kind : SymbolKind, qualified_name : String) : String
          "#{file}::#{kind.to_prolog_atom}::#{qualified_name}"
        end

        def owner_name(qualified_name : String) : String?
          Names.owner_name(qualified_name)
        end

        def simple_name(qualified_name : String) : String
          Names.simple_name(qualified_name)
        end

        private def lower_symbol(fact : DefinesFact) : SymbolNode
          SymbolNode.new(
            id: symbol_id(fact.file, fact.kind, fact.name),
            name: simple_name(fact.name),
            qualified_name: fact.name,
            owner_name: owner_name(fact.name),
            kind: fact.kind,
            file: fact.file,
            line: fact.line,
            end_line: fact.end_line,
            signature: fact.signature,
          )
        end

        private def lift_symbol(symbol : SymbolNode) : DefinesFact
          DefinesFact.new(
            file: symbol.file,
            name: symbol.qualified_name,
            kind: symbol.kind,
            line: symbol.line,
            end_line: symbol.end_line,
            signature: symbol.signature,
          )
        end

        private def lower_files(files : Array(Graph::FileNode)?) : Array(FileNode)
          return [] of FileNode unless files

          files.map do |file|
            FileNode.new(
              path: file.path,
              language: file.language,
              line_count: file.line_count,
              token_estimate: file.token_estimate,
              file_doc: file.file_doc,
            )
          end
        end

        private def lift_files(files : Array(FileNode)) : Array(Graph::FileNode)?
          return nil if files.empty?

          files.map do |file|
            Graph::FileNode.new(
              path: file.path,
              language: file.language,
              line_count: file.line_count,
              token_estimate: file.token_estimate,
              file_doc: file.file_doc,
            )
          end
        end
      end
    end
  end
end
