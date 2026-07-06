require "json"
require "option_parser"
require "./graph/ir"
require "./graph/types"
require "./graph/graph_util"
require "./graph/insights"
require "./graph/community"

module Chiasmus
  module Plan
    @@after_report_analyzed_hook_for_test : Proc(String, Nil)? = nil
    @@after_report_analyzed_hook_lock = Mutex.new

    enum Mode
      Rank
      Safe
    end

    record ParsedFacts,
      graph : Graph::CodeGraph,
      entry_points : Array(String),
      semantic_graph : Graph::IR::SemanticGraph? = nil,
      semantic_entry_points : Array(String)? = nil

    record AnalysisContext,
      forward : Hash(String, Set(String)),
      reverse : Hash(String, Set(String)),
      reachable : Set(String),
      degree : Hash(String, Int32),
      bridge_scores : Hash(String, Float64),
      community_by_node : Hash(String, Graph::Community),
      children_by_parent : Hash(String, Int32),
      exported : Set(String)

    record Report,
      name : String,
      file : String,
      kind : String,
      reachable_from_entry : Bool,
      dead_code : Bool,
      caller_count : Int32,
      callee_count : Int32,
      impact_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      community_id : Int32?,
      community_size : Int32,
      contains_count : Int32,
      priority_score : Int32,
      safety_score : Int32,
      reasons : Array(String),
      recommendation : String,
      owner_name : String? = nil

    record Slice,
      slice_id : String,
      slice_kind : String,
      members : Array(Report),
      priority_score : Int32,
      parallel_safe : Bool,
      reasons : Array(String)

    record TrackedSlice,
      slice_id : String,
      slice_kind : String,
      accepted_status : String,
      priority_score : Int32,
      parallel_safe : Bool,
      members : Array(Report),
      reasons : Array(String)

    record RefreshedSlice,
      slice_id : String,
      slice_kind : String,
      change_kind : String,
      accepted_status : String,
      priority_score : Int32,
      previous_priority_score : Int32?,
      parallel_safe : Bool,
      members : Array(Report),
      reasons : Array(String)

    record CLIOptions,
      facts_path : String,
      format : String,
      inventory_path : String,
      out_path : String,
      parity_plan_path : String,
      previous_facts_path : String,
      symbol : String,
      file : String,
      top_n : Int32?,
      entry_points : Array(String),
      help_requested : Bool

    class FeatureGroupIndex
      def initialize(@reports : Array(Report))
      end

      def groups : Hash(String, Array(Report))
        groups = Hash(String, Array(Report)).new { |hash, key| hash[key] = [] of Report }
        feature_reports = @reports.select { |report| report.recommendation == "feature" }
        owner_counts_by_file = Hash(Tuple(String, String), Int32).new(0)
        owner_files = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }

        feature_reports.each do |report|
          owner = report.owner_name
          next if owner.nil? || owner.blank?

          owner_counts_by_file[{owner, report.file}] += 1
          owner_files[owner] << report.file
        end

        feature_reports.each do |report|
          owner = report.owner_name
          key = if owner && !owner.blank? && owner_counts_by_file[{owner, report.file}] > 1
                  if owner_files[owner].size > 1
                    "owner:#{owner}@#{report.file}"
                  else
                    "owner:#{owner}"
                  end
                elsif report.community_id
                  "community:#{report.community_id}"
                else
                  "file:#{report.file}"
                end

          groups[key] << report
        end

        groups
      end
    end

    extend self

    def set_after_report_analyzed_hook_for_test(&block : String ->) : Nil
      @@after_report_analyzed_hook_lock.synchronize do
        @@after_report_analyzed_hook_for_test = block
      end
    end

    def clear_after_report_analyzed_hook_for_test : Nil
      @@after_report_analyzed_hook_lock.synchronize do
        @@after_report_analyzed_hook_for_test = nil
      end
    end

    def rank(graph : Graph::CodeGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Report)
      reports = analyze(graph, entry_points)
      ranked = reports.sort do |a, b|
        cmp = b.priority_score <=> a.priority_score
        cmp == 0 ? a.name <=> b.name : cmp
      end
      top_n ? ranked.first(top_n) : ranked
    end

    def rank(graph : Graph::IR::SemanticGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Report)
      reports = analyze(graph, entry_points)
      ranked = reports.sort do |a, b|
        cmp = b.priority_score <=> a.priority_score
        cmp == 0 ? a.name <=> b.name : cmp
      end
      top_n ? ranked.first(top_n) : ranked
    end

    def safe(graph : Graph::CodeGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Report)
      reports = analyze(graph, entry_points)
      ranked = reports.sort do |a, b|
        cmp = b.safety_score <=> a.safety_score
        cmp == 0 ? a.name <=> b.name : cmp
      end
      top_n ? ranked.first(top_n) : ranked
    end

    def safe(graph : Graph::IR::SemanticGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Report)
      reports = analyze(graph, entry_points)
      ranked = reports.sort do |a, b|
        cmp = b.safety_score <=> a.safety_score
        cmp == 0 ? a.name <=> b.name : cmp
      end
      top_n ? ranked.first(top_n) : ranked
    end

    def slice(graph : Graph::CodeGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Slice)
      reports = analyze(graph, entry_points)
      ordered_slices = order_slices_by_priority!(build_slices(reports))
      top_n ? ordered_slices.first(top_n) : ordered_slices
    end

    def slice(graph : Graph::IR::SemanticGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : Array(Slice)
      reports = analyze(graph, entry_points)
      ordered_slices = order_slices_by_priority!(build_slices(reports))
      top_n ? ordered_slices.first(top_n) : ordered_slices
    end

    def seed_parity(graph : Graph::CodeGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : String
      slices = slice(graph, entry_points: entry_points, top_n: top_n)
      render_seed_markdown(slices, entry_points || graph.exports.map(&.name))
    end

    def seed_parity(graph : Graph::IR::SemanticGraph, entry_points : Array(String)? = nil, top_n : Int32? = nil) : String
      normalized = Graph::IR.normalize(graph)
      slices = slice(normalized, entry_points: entry_points, top_n: top_n)
      effective_entry_points = entry_points || normalized.exports.map(&.name)
      render_seed_markdown(slices, effective_entry_points)
    end

    def track(
      graph : Graph::CodeGraph,
      parity_plan_path : String? = nil,
      entry_points : Array(String)? = nil,
      top_n : Int32? = nil,
    ) : Array(TrackedSlice)
      statuses = parse_parity_plan_statuses(parity_plan_path)
      slice(graph, entry_points: entry_points, top_n: top_n).map do |work_slice|
        TrackedSlice.new(
          slice_id: work_slice.slice_id,
          slice_kind: work_slice.slice_kind,
          accepted_status: statuses[work_slice.slice_id]? || "proposed",
          priority_score: work_slice.priority_score,
          parallel_safe: work_slice.parallel_safe,
          members: work_slice.members,
          reasons: work_slice.reasons,
        )
      end
    end

    def track(
      graph : Graph::IR::SemanticGraph,
      parity_plan_path : String? = nil,
      entry_points : Array(String)? = nil,
      top_n : Int32? = nil,
    ) : Array(TrackedSlice)
      statuses = parse_parity_plan_statuses(parity_plan_path)
      slice(graph, entry_points: entry_points, top_n: top_n).map do |work_slice|
        TrackedSlice.new(
          slice_id: work_slice.slice_id,
          slice_kind: work_slice.slice_kind,
          accepted_status: statuses[work_slice.slice_id]? || "proposed",
          priority_score: work_slice.priority_score,
          parallel_safe: work_slice.parallel_safe,
          members: work_slice.members,
          reasons: work_slice.reasons,
        )
      end
    end

    def audit(
      graph : Graph::CodeGraph,
      symbol : String,
      file : String? = nil,
      entry_points : Array(String)? = nil,
    ) : Report
      context = build_analysis_context(graph, entry_points)
      reports = graph.defines
        .select { |fact| fact.name == symbol }
        .select { |fact| file.nil? || fact.file == file }
        .map { |fact| analyze_fact(fact, context) }
      resolve_audit_report(reports, symbol, file)
    end

    def audit(
      graph : Graph::IR::SemanticGraph,
      symbol : String,
      file : String? = nil,
      entry_points : Array(String)? = nil,
    ) : Report
      normalized = Graph::IR.normalize(graph)
      analysis_graph = build_semantic_analysis_graph(normalized)
      context = build_analysis_context(analysis_graph, resolve_semantic_entry_points(normalized, entry_points))
      reports = normalized.symbols
        .select { |node| node.qualified_name == symbol }
        .select { |node| file.nil? || node.file == file }
        .map { |node| analyze_symbol(node, context, node.id) }
      resolve_audit_report(reports, symbol, file)
    end

    def refresh(
      graph : Graph::CodeGraph,
      previous_graph : Graph::CodeGraph,
      parity_plan_path : String? = nil,
      entry_points : Array(String)? = nil,
      top_n : Int32? = nil,
    ) : Array(RefreshedSlice)
      current = track(
        graph,
        parity_plan_path: parity_plan_path,
        entry_points: entry_points,
        top_n: top_n,
      )
      previous = slice(previous_graph, entry_points: entry_points, top_n: top_n)
      previous_by_id = previous.to_h { |slice| {slice.slice_id, slice} }

      current.compact_map do |current_slice|
        previous_slice = previous_by_id[current_slice.slice_id]?
        change_kind = detect_refresh_change(previous_slice, current_slice)
        next unless change_kind

        RefreshedSlice.new(
          slice_id: current_slice.slice_id,
          slice_kind: current_slice.slice_kind,
          change_kind: change_kind,
          accepted_status: current_slice.accepted_status,
          priority_score: current_slice.priority_score,
          previous_priority_score: previous_slice.try(&.priority_score),
          parallel_safe: current_slice.parallel_safe,
          members: current_slice.members,
          reasons: current_slice.reasons,
        )
      end
    end

    def refresh(
      graph : Graph::IR::SemanticGraph,
      previous_graph : Graph::IR::SemanticGraph,
      parity_plan_path : String? = nil,
      entry_points : Array(String)? = nil,
      top_n : Int32? = nil,
    ) : Array(RefreshedSlice)
      current = track(
        graph,
        parity_plan_path: parity_plan_path,
        entry_points: entry_points,
        top_n: top_n,
      )
      previous = slice(previous_graph, entry_points: entry_points, top_n: top_n)
      previous_by_id = previous.to_h { |slice| {slice.slice_id, slice} }

      current.compact_map do |current_slice|
        previous_slice = previous_by_id[current_slice.slice_id]?
        change_kind = detect_refresh_change(previous_slice, current_slice)
        next unless change_kind

        RefreshedSlice.new(
          slice_id: current_slice.slice_id,
          slice_kind: current_slice.slice_kind,
          change_kind: change_kind,
          accepted_status: current_slice.accepted_status,
          priority_score: current_slice.priority_score,
          previous_priority_score: previous_slice.try(&.priority_score),
          parallel_safe: current_slice.parallel_safe,
          members: current_slice.members,
          reasons: current_slice.reasons,
        )
      end
    end

    private def build_slices(reports : Array(Report)) : Array(Slice)
      slices = [] of Slice
      append_foundational_slices(slices, reports)
      append_cleanup_slice(slices, reports)
      append_safe_parallel_slice(slices, reports)
      append_feature_slices(slices, reports)
      slices
    end

    private def resolve_audit_report(reports : Array(Report), symbol : String, file : String?) : Report
      matches = reports.select { |report| report.name == symbol }
      matches = matches.select { |report| report.file == file } if file

      return matches.first if matches.size == 1

      if file
        raise "Unknown symbol: #{symbol} in #{file}" if matches.empty?
      else
        raise "Unknown symbol: #{symbol}" if matches.empty?
      end

      candidate_files = matches.map(&.file)
      candidate_files.sort!
      raise "Ambiguous symbol: #{symbol} (matches: #{candidate_files.join(", ")})"
    end

    private def append_foundational_slices(slices : Array(Slice), reports : Array(Report)) : Nil
      ordered_reports_by_priority(reports.select(&.recommendation.==("foundational"))).each do |report|
        slices << Slice.new(
          slice_id: "foundational:#{report.name}",
          slice_kind: "foundational",
          members: [report],
          priority_score: report.priority_score,
          parallel_safe: false,
          reasons: ["central integration point", *report.reasons],
        )
      end
    end

    private def append_cleanup_slice(slices : Array(Slice), reports : Array(Report)) : Nil
      cleanup = ordered_reports_by_name(reports.select(&.recommendation.==("cleanup")))
      return if cleanup.empty?

      slices << Slice.new(
        slice_id: "cleanup:dead-code",
        slice_kind: "cleanup",
        members: cleanup,
        priority_score: cleanup.sum(&.safety_score),
        parallel_safe: true,
        reasons: ["dead or unreachable code can be deferred or cleaned up"],
      )
    end

    private def append_safe_parallel_slice(slices : Array(Slice), reports : Array(Report)) : Nil
      safe_parallel = ordered_reports_by_name(reports.select { |report| report.recommendation == "safe_parallel" })
      return if safe_parallel.empty?

      slices << Slice.new(
        slice_id: "safe-parallel:batch-1",
        slice_kind: "safe_parallel",
        members: safe_parallel,
        priority_score: safe_parallel.sum(&.safety_score),
        parallel_safe: true,
        reasons: ["low-blast-radius work suitable for parallel execution"],
      )
    end

    private def append_feature_slices(slices : Array(Slice), reports : Array(Report)) : Nil
      FeatureGroupIndex.new(reports).groups.each do |key, members|
        ordered = ordered_reports_by_name(members)
        slices << Slice.new(
          slice_id: key,
          slice_kind: "feature",
          members: ordered,
          priority_score: ordered.sum(&.priority_score),
          parallel_safe: false,
          reasons: ["cohesive reachable workset grouped for branch-sized progress"],
        )
      end
    end

    private def ordered_reports_by_priority(reports : Array(Report)) : Array(Report)
      ordered = reports.dup
      ordered.sort! do |left, right|
        cmp = right.priority_score <=> left.priority_score
        cmp == 0 ? left.name <=> right.name : cmp
      end
      ordered
    end

    private def ordered_reports_by_name(reports : Array(Report)) : Array(Report)
      ordered = reports.dup
      ordered.sort_by!(&.name)
      ordered
    end

    private def order_slices_by_priority!(slices : Array(Slice)) : Array(Slice)
      slices.sort! do |left, right|
        cmp = right.priority_score <=> left.priority_score
        cmp == 0 ? left.slice_id <=> right.slice_id : cmp
      end
      slices
    end

    private def skip_line?(stripped : String) : Bool
      stripped.empty? || stripped.starts_with?('%') || stripped.starts_with?(":-") || stripped.includes?(":-")
    end

    def load_facts(path : String) : ParsedFacts
      defines = [] of Graph::DefinesFact
      calls = [] of Graph::CallsFact
      exports = [] of Graph::ExportsFact
      contains = [] of Graph::ContainsFact
      scoped_calls = [] of Graph::IR::ScopedCallEdge
      entry_points = [] of String
      entry_point_files = [] of Tuple(String, String)

      File.each_line(path) do |line|
        stripped = line.strip
        next if skip_line?(stripped)

        if stripped.starts_with?("defines(")
          args = parse_args(stripped["defines(".size...-2])
          defines << Graph::DefinesFact.new(
            file: atom(args[0]),
            name: atom(args[1]),
            kind: parse_symbol_kind(atom(args[2])),
            line: args[3].to_i,
            end_line: args[4].to_i,
          )
        elsif stripped.starts_with?("calls_in(")
          args = parse_args(stripped["calls_in(".size...-2])
          scoped_calls << Graph::IR::ScopedCallEdge.new(
            file: atom(args[0]),
            caller: atom(args[1]),
            callee: atom(args[2]),
          )
        elsif stripped.starts_with?("calls(")
          args = parse_args(stripped["calls(".size...-2])
          calls << Graph::CallsFact.new(
            caller: atom(args[0]),
            callee: atom(args[1]),
          )
        elsif stripped.starts_with?("exports(")
          args = parse_args(stripped["exports(".size...-2])
          exports << Graph::ExportsFact.new(
            file: atom(args[0]),
            name: atom(args[1]),
          )
        elsif stripped.starts_with?("contains(")
          args = parse_args(stripped["contains(".size...-2])
          contains << Graph::ContainsFact.new(
            parent: atom(args[0]),
            child: atom(args[1]),
          )
        elsif stripped.starts_with?("entry_point(")
          args = parse_args(stripped["entry_point(".size...-2])
          entry_points << atom(args[0])
        elsif stripped.starts_with?("entry_point_file(")
          args = parse_args(stripped["entry_point_file(".size...-2])
          entry_point_files << {atom(args[0]), atom(args[1])}
        end
      end

      graph = Graph::CodeGraph.new(
        defines: defines,
        calls: calls,
        exports: exports,
        contains: contains,
        imports: [] of Graph::ImportsFact,
      )

      semantic = Graph::IR::Lowering.from_code_graph(graph)
      semantic = semantic.copy_with(scoped_calls: scoped_calls) unless scoped_calls.empty?

      ParsedFacts.new(
        graph: graph,
        entry_points: entry_points,
        semantic_graph: semantic,
        semantic_entry_points: resolve_loaded_semantic_entry_points(graph, entry_point_files),
      )
    end

    private def resolve_loaded_semantic_entry_points(
      graph : Graph::CodeGraph,
      entry_point_files : Array(Tuple(String, String)),
    ) : Array(String)?
      return nil if entry_point_files.empty?

      semantic = Graph::IR::Lowering.from_code_graph(graph)
      index = Graph::IR::ScopedSymbolIndex.new(semantic.symbols)
      resolved = [] of String

      entry_point_files.each do |file, name|
        index.symbols_in_file(file, name).each do |symbol|
          resolved << symbol.id
        end
      end

      resolved.uniq!
      resolved
    end

    private def analyze(graph : Graph::CodeGraph, entry_points : Array(String)? = nil) : Array(Report)
      context = build_analysis_context(graph, entry_points)
      graph.defines.map { |fact| analyze_fact(fact, context) }
    end

    private def analyze(graph : Graph::IR::SemanticGraph, entry_points : Array(String)? = nil) : Array(Report)
      normalized = Graph::IR.normalize(graph)
      analysis_graph = build_semantic_analysis_graph(normalized)
      context = build_analysis_context(analysis_graph, resolve_semantic_entry_points(normalized, entry_points))
      normalized.symbols.map { |symbol| analyze_symbol(symbol, context, symbol.id) }
    end

    private def build_semantic_analysis_graph(graph : Graph::IR::SemanticGraph) : Graph::CodeGraph
      index = Graph::IR::ScopedSymbolIndex.new(graph.symbols)

      Graph::CodeGraph.new(
        defines: graph.symbols.map do |symbol|
          Graph::DefinesFact.new(
            file: symbol.file,
            name: symbol.id,
            kind: symbol.kind,
            line: symbol.line,
            end_line: symbol.end_line,
            signature: symbol.signature,
          )
        end,
        calls: resolve_semantic_calls(graph, index),
        imports: graph.imports.map { |edge| Graph::ImportsFact.new(edge.file, edge.name, edge.source) },
        exports: resolve_semantic_exports(graph, index),
        contains: resolve_semantic_contains(graph, index),
        files: graph.files.map { |file| Graph::FileNode.new(file.path, file.language, file.line_count, file.token_estimate, file.file_doc) },
        type_info: graph.type_info,
      )
    end

    private def resolve_semantic_entry_points(
      graph : Graph::IR::SemanticGraph,
      entry_points : Array(String)?,
    ) : Array(String)?
      return nil if entry_points.nil?

      index = Graph::IR::ScopedSymbolIndex.new(graph.symbols)
      entry_ids = entry_points.flat_map do |name|
        direct_ids = graph.symbols.select { |symbol| symbol.id == name }.map(&.id)
        next direct_ids unless direct_ids.empty?

        export_matches = graph.exports.compact_map do |edge|
          next unless edge.name == name

          resolve_semantic_symbol(index, edge.name, edge.file).try(&.id)
        end

        if export_matches.empty?
          index.symbols_named(name).map(&.id)
        else
          export_matches
        end
      end
      entry_ids.uniq!
      entry_ids
    end

    private def resolve_semantic_calls(
      graph : Graph::IR::SemanticGraph,
      index : Graph::IR::ScopedSymbolIndex,
    ) : Array(Graph::CallsFact)
      resolved = [] of Graph::CallsFact

      scoped_constraint = build_scoped_constraint(graph.scoped_calls)

      graph.calls.each do |edge|
        callers = index.symbols_named(edge.caller)
        caller_is_unique = callers.size == 1

        callers.each do |caller|
          if constraint = scoped_constraint
            next unless constraint.includes?({caller.file, edge.caller, edge.callee})
          end

          callee = resolve_semantic_call_callee(index, edge.callee, caller.file, edge.callee_qn, caller_is_unique)
          next unless callee

          resolved << Graph::CallsFact.new(caller: caller.id, callee: callee.id)
        end
      end

      deduplicate_semantic_calls(resolved)
    end

    private def build_scoped_constraint(scoped_calls : Array(Graph::IR::ScopedCallEdge)) : Set(Tuple(String, String, String))?
      return nil if scoped_calls.empty?

      constraint = Set(Tuple(String, String, String)).new
      scoped_calls.each do |edge|
        constraint.add({edge.file, edge.caller, edge.callee})
      end
      constraint
    end

    private def resolve_semantic_call_callee(
      index : Graph::IR::ScopedSymbolIndex,
      qualified_name : String,
      file : String,
      expected_qn : String?,
      caller_is_unique : Bool,
    ) : Graph::IR::SymbolNode?
      local_matches = index.symbols_in_file(file, qualified_name)
      local_matches = local_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
      return local_matches.first if local_matches.size == 1
      return nil unless caller_is_unique

      global_matches = index.symbols_named(qualified_name)
      global_matches = global_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
      return global_matches.first if global_matches.size == 1

      nil
    end

    private def resolve_semantic_exports(
      graph : Graph::IR::SemanticGraph,
      index : Graph::IR::ScopedSymbolIndex,
    ) : Array(Graph::ExportsFact)
      graph.exports.compact_map do |edge|
        symbol = resolve_semantic_symbol(index, edge.name, edge.file)
        next unless symbol

        Graph::ExportsFact.new(edge.file, symbol.id)
      end
    end

    private def resolve_semantic_contains(
      graph : Graph::IR::SemanticGraph,
      index : Graph::IR::ScopedSymbolIndex,
    ) : Array(Graph::ContainsFact)
      resolved = [] of Graph::ContainsFact

      graph.contains.each do |edge|
        index.symbols_named(edge.parent).each do |parent|
          next unless semantic_container_kind?(parent.kind)

          child = resolve_semantic_symbol(index, edge.child, parent.file)
          next unless child

          resolved << Graph::ContainsFact.new(parent.id, child.id)
        end
      end

      deduplicate_semantic_contains(resolved)
    end

    private def resolve_semantic_symbol(
      index : Graph::IR::ScopedSymbolIndex,
      qualified_name : String,
      file : String,
      expected_qn : String? = nil,
    ) : Graph::IR::SymbolNode?
      local_matches = index.symbols_in_file(file, qualified_name)
      local_matches = local_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
      return local_matches.first if local_matches.size == 1

      global_matches = index.symbols_named(qualified_name)
      global_matches = global_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
      return global_matches.first if global_matches.size == 1

      nil
    end

    private def semantic_container_kind?(kind : Graph::SymbolKind) : Bool
      kind.in?(Graph::SymbolKind::Class, Graph::SymbolKind::Interface, Graph::SymbolKind::Module, Graph::SymbolKind::Type)
    end

    private def deduplicate_semantic_calls(calls : Array(Graph::CallsFact)) : Array(Graph::CallsFact)
      seen = Set(String).new
      calls.select { |edge| seen.add?("#{edge.caller}\u0000#{edge.callee}") }
    end

    private def deduplicate_semantic_contains(contains : Array(Graph::ContainsFact)) : Array(Graph::ContainsFact)
      seen = Set(String).new
      contains.select { |edge| seen.add?("#{edge.parent}\u0000#{edge.child}") }
    end

    private def build_analysis_context(graph : Graph::CodeGraph, entry_points : Array(String)?) : AnalysisContext
      forward = adjacency(graph.calls, forward: true)
      reverse = adjacency(graph.calls, forward: false)
      AnalysisContext.new(
        forward: forward,
        reverse: reverse,
        reachable: reachable_from_roots(forward, effective_roots(graph, entry_points)),
        degree: Graph::GraphUtil.undirected_degree(graph),
        bridge_scores: build_bridge_scores(graph),
        community_by_node: build_community_by_node(graph),
        children_by_parent: build_children_by_parent(graph),
        exported: graph.exports.map(&.name).to_set,
      )
    end

    private def effective_roots(graph : Graph::CodeGraph, entry_points : Array(String)?) : Array(String)
      roots = (entry_points || graph.exports.map(&.name)).dup
      roots.uniq!
      roots
    end

    private def build_bridge_scores(graph : Graph::CodeGraph) : Hash(String, Float64)
      scores = Hash(String, Float64).new(0.0)
      Graph::Insights.detect_bridges(graph).each do |bridge|
        scores[bridge.name] = bridge.score
      end
      scores
    end

    private def build_community_by_node(graph : Graph::CodeGraph) : Hash(String, Graph::Community)
      communities = Hash(String, Graph::Community).new
      Graph::CommunityDetection.detect(graph).each do |community|
        community.members.each do |member|
          communities[member] = community
        end
      end
      communities
    end

    private def build_children_by_parent(graph : Graph::CodeGraph) : Hash(String, Int32)
      children = Hash(String, Int32).new(0)
      graph.contains.each do |fact|
        children[fact.parent] += 1
      end
      children
    end

    private def analyze_fact(fact : Graph::DefinesFact, context : AnalysisContext) : Report
      reachable_from_entry = context.reachable.includes?(fact.name)
      caller_count = context.reverse[fact.name]?.try(&.size) || 0
      callee_count = context.forward[fact.name]?.try(&.size) || 0
      impact_count = reverse_reach_count(context.reverse, fact.name)
      hub_degree = context.degree[fact.name]? || 0
      bridge_score = context.bridge_scores[fact.name]? || 0.0
      community = context.community_by_node[fact.name]?
      community_size = community.try(&.members.size) || 1
      contains_count = context.children_by_parent[fact.name]? || 0
      exported = context.exported.includes?(fact.name)
      dead_code = !reachable_from_entry && caller_count == 0
      priority_score = priority_score_for(reachable_from_entry, exported, impact_count, caller_count, hub_degree, bridge_score, contains_count, community_size)
      safety_score = safety_score_for(reachable_from_entry, dead_code, impact_count, caller_count, hub_degree, bridge_score, community_size, callee_count)
      reasons = report_reasons(reachable_from_entry, exported, impact_count, hub_degree, bridge_score, dead_code, community_size)
      recommendation = recommendation_for(dead_code, reachable_from_entry, callee_count, hub_degree, bridge_score, contains_count, safety_score)

      report = Report.new(
        name: fact.name,
        file: fact.file,
        kind: fact.kind.to_s.downcase,
        owner_name: Graph::IR::Lowering.owner_name(fact.name),
        reachable_from_entry: reachable_from_entry,
        dead_code: dead_code,
        caller_count: caller_count,
        callee_count: callee_count,
        impact_count: impact_count,
        hub_degree: hub_degree,
        bridge_score: bridge_score,
        community_id: community.try(&.id),
        community_size: community_size,
        contains_count: contains_count,
        priority_score: priority_score,
        safety_score: safety_score,
        reasons: reasons,
        recommendation: recommendation,
      )
      notify_after_report_analyzed_for_test(report.name)
      report
    end

    private def analyze_symbol(
      symbol : Graph::IR::SymbolNode,
      context : AnalysisContext,
      analysis_key : String = symbol.qualified_name,
    ) : Report
      reachable_from_entry = context.reachable.includes?(analysis_key)
      caller_count = context.reverse[analysis_key]?.try(&.size) || 0
      callee_count = context.forward[analysis_key]?.try(&.size) || 0
      impact_count = reverse_reach_count(context.reverse, analysis_key)
      hub_degree = context.degree[analysis_key]? || 0
      bridge_score = context.bridge_scores[analysis_key]? || 0.0
      community = context.community_by_node[analysis_key]?
      community_size = community.try(&.members.size) || 1
      contains_count = context.children_by_parent[analysis_key]? || 0
      exported = context.exported.includes?(analysis_key)
      dead_code = !reachable_from_entry && caller_count == 0
      priority_score = priority_score_for(reachable_from_entry, exported, impact_count, caller_count, hub_degree, bridge_score, contains_count, community_size)
      safety_score = safety_score_for(reachable_from_entry, dead_code, impact_count, caller_count, hub_degree, bridge_score, community_size, callee_count)
      reasons = report_reasons(reachable_from_entry, exported, impact_count, hub_degree, bridge_score, dead_code, community_size)
      recommendation = recommendation_for(dead_code, reachable_from_entry, callee_count, hub_degree, bridge_score, contains_count, safety_score)

      report = Report.new(
        name: symbol.qualified_name,
        file: symbol.file,
        kind: symbol.kind.to_s.downcase,
        owner_name: symbol.owner_name,
        reachable_from_entry: reachable_from_entry,
        dead_code: dead_code,
        caller_count: caller_count,
        callee_count: callee_count,
        impact_count: impact_count,
        hub_degree: hub_degree,
        bridge_score: bridge_score,
        community_id: community.try(&.id),
        community_size: community_size,
        contains_count: contains_count,
        priority_score: priority_score,
        safety_score: safety_score,
        reasons: reasons,
        recommendation: recommendation,
      )
      notify_after_report_analyzed_for_test(report.name)
      report
    end

    private def notify_after_report_analyzed_for_test(name : String) : Nil
      hook = @@after_report_analyzed_hook_lock.synchronize do
        @@after_report_analyzed_hook_for_test
      end
      hook.try &.call(name)
    end

    private def priority_score_for(
      reachable_from_entry : Bool,
      exported : Bool,
      impact_count : Int32,
      caller_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      contains_count : Int32,
      community_size : Int32,
    ) : Int32
      score = 0
      score += 100 if reachable_from_entry
      score += 30 if exported
      score += impact_count * 10
      score += caller_count * 5
      score += hub_degree * 4
      score += (bridge_score * 100).round.to_i
      score += contains_count * 2
      score += 10 if community_size > 1
      score
    end

    private def safety_score_for(
      reachable_from_entry : Bool,
      dead_code : Bool,
      impact_count : Int32,
      caller_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      community_size : Int32,
      callee_count : Int32,
    ) : Int32
      score = 0
      score += 100 unless reachable_from_entry
      score += 40 if dead_code
      score += Math.max(0, 40 - impact_count * 10)
      score += Math.max(0, 20 - caller_count * 5)
      score += 10 if hub_degree == 0
      score += 10 if bridge_score == 0.0
      score += 10 if community_size <= 1
      score += 10 if callee_count == 0
      score
    end

    private def report_reasons(
      reachable_from_entry : Bool,
      exported : Bool,
      impact_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      dead_code : Bool,
      community_size : Int32,
    ) : Array(String)
      reasons = [] of String
      if reachable_from_entry
        reasons << "reachable from entry point"
      else
        reasons << "not reachable from entry points"
      end
      reasons << "exported surface" if exported
      reasons << "impact radius #{impact_count}" if impact_count > 0
      reasons << "hub degree #{hub_degree}" if hub_degree > 0
      reasons << "bridge score #{bridge_score.round(2)}" if bridge_score > 0.0
      reasons << "dead code candidate" if dead_code
      reasons << "isolated community" if community_size <= 1
      reasons
    end

    private def recommendation_for(
      dead_code : Bool,
      reachable_from_entry : Bool,
      callee_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      contains_count : Int32,
      safety_score : Int32,
    ) : String
      return "cleanup" if dead_code
      return "foundational" if foundational?(reachable_from_entry, callee_count, hub_degree, bridge_score, contains_count)
      return "safe_parallel" if safety_score >= 120

      "feature"
    end

    private def adjacency(calls : Array(Graph::CallsFact), *, forward : Bool) : Hash(String, Set(String))
      graph = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
      calls.each do |fact|
        key = forward ? fact.caller : fact.callee
        value = forward ? fact.callee : fact.caller
        graph[key] << value
        graph[value] = Set(String).new unless graph.has_key?(value)
      end
      graph
    end

    private def reachable_from_roots(adjacency : Hash(String, Set(String)), roots : Array(String)) : Set(String)
      reachable = Set(String).new
      queue = roots.dup

      until queue.empty?
        current = queue.shift
        next if reachable.includes?(current)
        reachable << current
        adjacency[current]?.try(&.each do |next_name|
          queue << next_name unless reachable.includes?(next_name)
        end)
      end

      reachable
    end

    private def reverse_reach_count(reverse : Hash(String, Set(String)), target : String) : Int32
      visited = Set(String).new
      queue = reverse[target]?.try(&.to_a) || [] of String

      until queue.empty?
        current = queue.shift
        next if visited.includes?(current)
        visited << current
        reverse[current]?.try(&.each do |next_name|
          queue << next_name unless visited.includes?(next_name)
        end)
      end

      visited.size
    end

    private def foundational?(
      reachable_from_entry : Bool,
      callee_count : Int32,
      hub_degree : Int32,
      bridge_score : Float64,
      contains_count : Int32,
    ) : Bool
      return false unless reachable_from_entry
      return false if callee_count == 0

      hub_degree >= 2 || bridge_score >= 0.25 || contains_count > 0
    end

    private def render_seed_markdown(slices : Array(Slice), entry_points : Array(String)) : String
      builder = String::Builder.new
      builder << "# Seed Parity Plan\n\n"
      builder << "Generated from graph facts."
      unless entry_points.empty?
        builder << " Entry points: "
        builder << entry_points.map { |name| "`#{name}`" }.join(", ")
        builder << "."
      end
      builder << "\n\n"

      sections = [
        {"Proposed Foundational Work", "foundational"},
        {"Proposed Feature Work", "feature"},
        {"Proposed Safe Parallel Work", "safe_parallel"},
        {"Proposed Cleanup Or Deferred Work", "cleanup"},
      ]

      sections.each do |title, kind|
        builder << "## #{title}\n\n"
        matching = slices.select { |slice| slice.slice_kind == kind }
        if matching.empty?
          builder << "- None.\n\n"
          next
        end

        matching.each do |slice|
          builder << "### `#{slice.slice_id}`\n\n"
          builder << "- Status: `proposed`\n"
          builder << "- Kind: `#{slice.slice_kind}`\n"
          builder << "- Priority: `#{slice.priority_score}`\n"
          builder << "- Parallel safe: `#{slice.parallel_safe}`\n"
          builder << "- Members: #{slice.members.map { |member| "`#{member.name}`" }.join(", ")}\n"
          builder << "- Reasons: #{slice.reasons.join("; ")}\n\n"
        end
      end

      builder.to_s
    end

    def render_audit_markdown(report : Report) : String
      builder = String::Builder.new
      builder << "# Audit: `#{report.name}`\n\n"
      builder << "- File: `#{report.file}`\n"
      builder << "- Kind: `#{report.kind}`\n"
      builder << "- Recommendation: `#{report.recommendation}`\n"
      builder << "- Reachable from entry: `#{report.reachable_from_entry}`\n"
      builder << "- Dead code: `#{report.dead_code}`\n"
      builder << "- Priority score: `#{report.priority_score}`\n"
      builder << "- Safety score: `#{report.safety_score}`\n"
      builder << "- Caller count: `#{report.caller_count}`\n"
      builder << "- Callee count: `#{report.callee_count}`\n"
      builder << "- Impact count: `#{report.impact_count}`\n"
      builder << "- Hub degree: `#{report.hub_degree}`\n"
      builder << "- Bridge score: `#{report.bridge_score}`\n"
      builder << "- Community id: `#{report.community_id.try(&.to_s) || "-"}`\n"
      builder << "- Community size: `#{report.community_size}`\n"
      builder << "- Contains count: `#{report.contains_count}`\n"
      builder << "\n## Reasons\n\n"
      report.reasons.each do |reason|
        builder << "- #{reason}\n"
      end
      builder.to_s
    end

    private def detect_refresh_change(previous_slice : Slice?, current_slice : TrackedSlice) : String?
      return "new_slice" unless previous_slice
      return "newly_risky" if previous_slice.parallel_safe && !current_slice.parallel_safe
      return "members_changed" if member_names(previous_slice.members) != member_names(current_slice.members)
      return "priority_changed" if previous_slice.priority_score != current_slice.priority_score

      nil
    end

    private def member_names(reports : Array(Report)) : Array(String)
      names = reports.map(&.name)
      names.sort!
      names
    end

    private def parse_parity_plan_statuses(parity_plan_path : String?) : Hash(String, String)
      statuses = Hash(String, String).new
      return statuses if parity_plan_path.nil? || parity_plan_path.blank?

      current_slice_id : String? = nil
      File.each_line(parity_plan_path) do |line|
        stripped = line.strip
        if match = /^### `([^`]+)`$/.match(stripped)
          current_slice_id = match[1]
          next
        end

        next unless current_slice_id

        if match = /^- Status: `([^`]+)`$/.match(stripped)
          statuses[current_slice_id] = match[1]
        elsif match = /^- Status: ([A-Za-z_]+)$/.match(stripped)
          statuses[current_slice_id] = match[1]
        end
      end

      statuses
    end

    private def parse_symbol_kind(value : String) : Graph::SymbolKind
      case value
      when "function"  then Graph::SymbolKind::Function
      when "method"    then Graph::SymbolKind::Method
      when "class"     then Graph::SymbolKind::Class
      when "interface" then Graph::SymbolKind::Interface
      when "type"      then Graph::SymbolKind::Type
      when "variable"  then Graph::SymbolKind::Variable
      when "module"    then Graph::SymbolKind::Module
      else
        raise "Unknown symbol kind in facts: #{value}"
      end
    end

    private def atom(value : String) : String
      stripped = value.strip
      if stripped.starts_with?('\'') && stripped.ends_with?('\'')
        stripped[1...-1].gsub("''", "'")
      else
        stripped
      end
    end

    private def parse_args(body : String) : Array(String)
      args = [] of String
      current = String::Builder.new
      in_quote = false
      i = 0

      while i < body.bytesize
        ch = body.byte_at(i).unsafe_chr
        if ch == '\''
          if in_quote && i + 1 < body.bytesize && body.byte_at(i + 1).unsafe_chr == '\''
            current << '\''
            i += 1
          else
            in_quote = !in_quote
            current << ch
          end
        elsif ch == ',' && !in_quote
          args << current.to_s.strip
          current = String::Builder.new
        else
          current << ch
        end
        i += 1
      end

      final = current.to_s.strip
      args << final unless final.empty?
      args
    end

    module CLI
      extend self

      def run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
        mode = args.first?
        return render_help(output) unless mode
        return render_help(output) if help_mode?(mode)
        return invalid_mode(mode, error) unless valid_mode?(mode)

        options, parser = parse_cli_options(args[1..], error)
        return 1 unless options
        return render_help(output) if options.help_requested
        return missing_facts(parser, error) if options.facts_path.empty?

        parsed = Plan.load_facts(options.facts_path)
        execute_mode(mode, options, parser, parsed, output, error)
      rescue ex
        error.puts ex.message || ex.class.name
        1
      end

      private def help_mode?(mode : String) : Bool
        %w[--help -h help].includes?(mode)
      end

      private def valid_mode?(mode : String) : Bool
        %w[rank safe slice seed-parity track audit refresh].includes?(mode)
      end

      private def parse_cli_options(args : Array(String), error : IO) : Tuple(CLIOptions?, OptionParser)
        facts_path = ""
        format = "tsv"
        inventory_path = ""
        out_path = ""
        parity_plan_path = ""
        previous_facts_path = ""
        symbol = ""
        file = ""
        top_n : Int32? = nil
        entry_points = [] of String
        help_requested = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: chiasmus-plan <rank|safe|slice|seed-parity|track|audit|refresh> --facts FILE [options]"
          opts.on("--facts FILE", "Path to layer-A Prolog facts emitted by chiasmus-facts") { |value| facts_path = value }
          opts.on("--format FORMAT", "Output format: tsv|json (default: tsv)") { |value| format = value }
          opts.on("--inventory FILE", "Path to curated parity inventory TSV") { |value| inventory_path = value }
          opts.on("--out FILE", "Write Markdown seed output to FILE") { |value| out_path = value }
          opts.on("--parity-plan FILE", "Path to curated parity Markdown plan") { |value| parity_plan_path = value }
          opts.on("--previous-facts FILE", "Path to previous layer-A Prolog facts for refresh") { |value| previous_facts_path = value }
          opts.on("--symbol NAME", "Symbol to audit") { |value| symbol = value }
          opts.on("--file PATH", "Disambiguate audit symbol by source file") { |value| file = value }
          opts.on("--top N", "Limit output rows") { |value| top_n = value.to_i }
          opts.on("--entry-point NAME", "Override entry points from the facts file (repeatable)") { |value| entry_points << value }
          opts.on("--help", "Show this help") { help_requested = true }
        end

        begin
          parser.parse(args)
        rescue ex
          error.puts ex.message
          error.puts parser
          return {nil, parser}
        end

        {
          CLIOptions.new(
            facts_path: facts_path,
            format: format,
            inventory_path: inventory_path,
            out_path: out_path,
            parity_plan_path: parity_plan_path,
            previous_facts_path: previous_facts_path,
            symbol: symbol,
            file: file,
            top_n: top_n,
            entry_points: entry_points,
            help_requested: help_requested,
          ),
          parser,
        }
      end

      private def execute_mode(
        mode : String,
        options : CLIOptions,
        parser : OptionParser,
        parsed : ParsedFacts,
        output : IO,
        error : IO,
      ) : Int32
        effective_entry_points = if options.entry_points.empty?
                                   parsed.semantic_entry_points || parsed.entry_points
                                 else
                                   options.entry_points
                                 end

        case mode
        when "rank"
          execute_rank_mode(mode, options, parsed, effective_entry_points, output)
        when "safe"
          execute_safe_mode(mode, options, parsed, effective_entry_points, output)
        when "seed-parity"
          execute_seed_parity_mode(options, parsed, effective_entry_points, output)
        when "track"
          execute_track_mode(mode, options, parsed, effective_entry_points, output)
        when "audit"
          execute_audit_mode(mode, options, parser, parsed, effective_entry_points, output, error)
        when "refresh"
          execute_refresh_mode(mode, options, parser, parsed, effective_entry_points, output, error)
        else
          execute_slice_mode(mode, options, parsed, effective_entry_points, output)
        end
      end

      private def execute_rank_mode(
        mode : String,
        options : CLIOptions,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
      ) : Int32
        reports = if semantic_graph = parsed.semantic_graph
                    Plan.rank(semantic_graph, entry_points: effective_entry_points, top_n: options.top_n)
                  else
                    Plan.rank(parsed.graph, entry_points: effective_entry_points, top_n: options.top_n)
                  end
        render_report_output(output, mode, options.format, reports)
      end

      private def execute_safe_mode(
        mode : String,
        options : CLIOptions,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
      ) : Int32
        reports = if semantic_graph = parsed.semantic_graph
                    Plan.safe(semantic_graph, entry_points: effective_entry_points, top_n: options.top_n)
                  else
                    Plan.safe(parsed.graph, entry_points: effective_entry_points, top_n: options.top_n)
                  end
        render_report_output(output, mode, options.format, reports)
      end

      private def execute_seed_parity_mode(
        options : CLIOptions,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
      ) : Int32
        seed = if semantic_graph = parsed.semantic_graph
                 Plan.seed_parity(semantic_graph, entry_points: effective_entry_points, top_n: options.top_n)
               else
                 Plan.seed_parity(parsed.graph, entry_points: effective_entry_points, top_n: options.top_n)
               end
        if options.out_path.empty?
          output.print seed
        else
          File.write(options.out_path, seed)
        end
        0
      end

      private def execute_track_mode(
        mode : String,
        options : CLIOptions,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
      ) : Int32
        tracked = if semantic_graph = parsed.semantic_graph
                    Plan.track(
                      semantic_graph,
                      parity_plan_path: options.parity_plan_path.empty? ? nil : options.parity_plan_path,
                      entry_points: effective_entry_points,
                      top_n: options.top_n,
                    )
                  else
                    Plan.track(
                      parsed.graph,
                      parity_plan_path: options.parity_plan_path.empty? ? nil : options.parity_plan_path,
                      entry_points: effective_entry_points,
                      top_n: options.top_n,
                    )
                  end
        if options.format == "json"
          render_track_json(output, mode, tracked, options.inventory_path)
        else
          render_track_tsv(output, mode, tracked, options.inventory_path)
        end
        0
      end

      private def execute_audit_mode(
        mode : String,
        options : CLIOptions,
        parser : OptionParser,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
        error : IO,
      ) : Int32
        if options.symbol.empty?
          error.puts "--symbol is required for audit"
          error.puts parser
          return 1
        end

        report = if semantic_graph = parsed.semantic_graph
                   Plan.audit(
                     semantic_graph,
                     symbol: options.symbol,
                     file: options.file.empty? ? nil : options.file,
                     entry_points: effective_entry_points
                   )
                 else
                   Plan.audit(
                     parsed.graph,
                     symbol: options.symbol,
                     file: options.file.empty? ? nil : options.file,
                     entry_points: effective_entry_points
                   )
                 end
        if options.format == "json"
          render_audit_json(output, mode, report)
        else
          output.print(Plan.render_audit_markdown(report))
        end
        0
      end

      private def execute_refresh_mode(
        mode : String,
        options : CLIOptions,
        parser : OptionParser,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
        error : IO,
      ) : Int32
        if options.previous_facts_path.empty?
          error.puts "--previous-facts is required for refresh"
          error.puts parser
          return 1
        end

        previous = Plan.load_facts(options.previous_facts_path)
        refreshed = if semantic_graph = parsed.semantic_graph
                      previous_semantic = previous.semantic_graph || Graph::IR::Lowering.from_code_graph(previous.graph)
                      Plan.refresh(
                        semantic_graph,
                        previous_graph: previous_semantic,
                        parity_plan_path: options.parity_plan_path.empty? ? nil : options.parity_plan_path,
                        entry_points: effective_entry_points,
                        top_n: options.top_n,
                      )
                    else
                      Plan.refresh(
                        parsed.graph,
                        previous_graph: previous.graph,
                        parity_plan_path: options.parity_plan_path.empty? ? nil : options.parity_plan_path,
                        entry_points: effective_entry_points,
                        top_n: options.top_n,
                      )
                    end
        if options.format == "json"
          render_refresh_json(output, mode, refreshed, options.previous_facts_path)
        else
          render_refresh_tsv(output, mode, refreshed, options.previous_facts_path)
        end
        0
      end

      private def execute_slice_mode(
        mode : String,
        options : CLIOptions,
        parsed : ParsedFacts,
        effective_entry_points : Array(String),
        output : IO,
      ) : Int32
        slices = if semantic_graph = parsed.semantic_graph
                   Plan.slice(semantic_graph, entry_points: effective_entry_points, top_n: options.top_n)
                 else
                   Plan.slice(parsed.graph, entry_points: effective_entry_points, top_n: options.top_n)
                 end
        if options.format == "json"
          render_slice_json(output, mode, slices)
        else
          render_slice_tsv(output, mode, slices)
        end
        0
      end

      private def render_report_output(output : IO, mode : String, format : String, reports : Array(Report)) : Int32
        if format == "json"
          render_json(output, mode, reports)
        else
          render_tsv(output, mode, reports)
        end
        0
      end

      private def missing_facts(parser : OptionParser, error : IO) : Int32
        error.puts "--facts is required"
        error.puts parser
        1
      end

      private def render_tsv(output : IO, mode : String, reports : Array(Report)) : Nil
        output.puts "# mode=#{mode}"
        output.puts "# name\tfile\tkind\treachable_from_entry\tdead_code\tcaller_count\tcallee_count\timpact_count\thub_degree\tbridge_score\tcommunity_id\tcommunity_size\tcontains_count\tpriority_score\tsafety_score\trecommendation\treasons"
        reports.each do |report|
          output.puts [
            report.name,
            report.file,
            report.kind,
            report.reachable_from_entry.to_s,
            report.dead_code.to_s,
            report.caller_count.to_s,
            report.callee_count.to_s,
            report.impact_count.to_s,
            report.hub_degree.to_s,
            report.bridge_score.to_s,
            report.community_id.try(&.to_s) || "-",
            report.community_size.to_s,
            report.contains_count.to_s,
            report.priority_score.to_s,
            report.safety_score.to_s,
            report.recommendation,
            report.reasons.join("; "),
          ].join('\t')
        end
      end

      private def render_json(output : IO, mode : String, reports : Array(Report)) : Nil
        payload = {
          "mode"    => mode,
          "reports" => reports.map do |report|
            {
              "name"                 => report.name,
              "file"                 => report.file,
              "kind"                 => report.kind,
              "reachable_from_entry" => report.reachable_from_entry,
              "dead_code"            => report.dead_code,
              "caller_count"         => report.caller_count,
              "callee_count"         => report.callee_count,
              "impact_count"         => report.impact_count,
              "hub_degree"           => report.hub_degree,
              "bridge_score"         => report.bridge_score,
              "community_id"         => report.community_id,
              "community_size"       => report.community_size,
              "contains_count"       => report.contains_count,
              "priority_score"       => report.priority_score,
              "safety_score"         => report.safety_score,
              "recommendation"       => report.recommendation,
              "reasons"              => report.reasons,
            }
          end,
        }
        output.puts payload.to_json
      end

      private def render_slice_tsv(output : IO, mode : String, slices : Array(Slice)) : Nil
        output.puts "# mode=#{mode}"
        output.puts "# slice_id\tslice_kind\tpriority_score\tparallel_safe\tmembers\treasons"
        slices.each do |slice|
          output.puts [
            slice.slice_id,
            slice.slice_kind,
            slice.priority_score.to_s,
            slice.parallel_safe.to_s,
            slice.members.map(&.name).join(","),
            slice.reasons.join("; "),
          ].join('\t')
        end
      end

      private def render_slice_json(output : IO, mode : String, slices : Array(Slice)) : Nil
        payload = {
          "mode"   => mode,
          "slices" => slices.map do |slice|
            {
              "slice_id"       => slice.slice_id,
              "slice_kind"     => slice.slice_kind,
              "priority_score" => slice.priority_score,
              "parallel_safe"  => slice.parallel_safe,
              "members"        => slice.members.map(&.name),
              "reasons"        => slice.reasons,
            }
          end,
        }
        output.puts payload.to_json
      end

      private def render_track_tsv(output : IO, mode : String, slices : Array(TrackedSlice), inventory_path : String) : Nil
        output.puts "# mode=#{mode}"
        output.puts "# inventory=#{inventory_path.empty? ? "-" : inventory_path}"
        output.puts "# slice_id\tslice_kind\taccepted_status\tpriority_score\tparallel_safe\tmembers\treasons"
        slices.each do |slice|
          output.puts [
            slice.slice_id,
            slice.slice_kind,
            slice.accepted_status,
            slice.priority_score.to_s,
            slice.parallel_safe.to_s,
            slice.members.map(&.name).join(","),
            slice.reasons.join("; "),
          ].join('\t')
        end
      end

      private def render_track_json(output : IO, mode : String, slices : Array(TrackedSlice), inventory_path : String) : Nil
        payload = {
          "mode"      => mode,
          "inventory" => inventory_path.empty? ? nil : inventory_path,
          "slices"    => slices.map do |slice|
            {
              "slice_id"        => slice.slice_id,
              "slice_kind"      => slice.slice_kind,
              "accepted_status" => slice.accepted_status,
              "priority_score"  => slice.priority_score,
              "parallel_safe"   => slice.parallel_safe,
              "members"         => slice.members.map(&.name),
              "reasons"         => slice.reasons,
            }
          end,
        }
        output.puts payload.to_json
      end

      private def render_audit_json(output : IO, mode : String, report : Report) : Nil
        payload = {
          "mode"   => mode,
          "report" => {
            "name"                 => report.name,
            "file"                 => report.file,
            "kind"                 => report.kind,
            "reachable_from_entry" => report.reachable_from_entry,
            "dead_code"            => report.dead_code,
            "caller_count"         => report.caller_count,
            "callee_count"         => report.callee_count,
            "impact_count"         => report.impact_count,
            "hub_degree"           => report.hub_degree,
            "bridge_score"         => report.bridge_score,
            "community_id"         => report.community_id,
            "community_size"       => report.community_size,
            "contains_count"       => report.contains_count,
            "priority_score"       => report.priority_score,
            "safety_score"         => report.safety_score,
            "recommendation"       => report.recommendation,
            "reasons"              => report.reasons,
          },
        }
        output.puts payload.to_json
      end

      private def render_refresh_tsv(output : IO, mode : String, slices : Array(RefreshedSlice), previous_facts_path : String) : Nil
        output.puts "# mode=#{mode}"
        output.puts "# previous_facts=#{previous_facts_path}"
        output.puts "# slice_id\tslice_kind\tchange_kind\taccepted_status\tpriority_score\tprevious_priority_score\tparallel_safe\tmembers\treasons"
        slices.each do |slice|
          output.puts [
            slice.slice_id,
            slice.slice_kind,
            slice.change_kind,
            slice.accepted_status,
            slice.priority_score.to_s,
            slice.previous_priority_score.try(&.to_s) || "-",
            slice.parallel_safe.to_s,
            slice.members.map(&.name).join(","),
            slice.reasons.join("; "),
          ].join('\t')
        end
      end

      private def render_refresh_json(output : IO, mode : String, slices : Array(RefreshedSlice), previous_facts_path : String) : Nil
        payload = {
          "mode"           => mode,
          "previous_facts" => previous_facts_path,
          "slices"         => slices.map do |slice|
            {
              "slice_id"                => slice.slice_id,
              "slice_kind"              => slice.slice_kind,
              "change_kind"             => slice.change_kind,
              "accepted_status"         => slice.accepted_status,
              "priority_score"          => slice.priority_score,
              "previous_priority_score" => slice.previous_priority_score,
              "parallel_safe"           => slice.parallel_safe,
              "members"                 => slice.members.map(&.name),
              "reasons"                 => slice.reasons,
            }
          end,
        }
        output.puts payload.to_json
      end

      private def render_help(output : IO) : Int32
        output.puts "Usage: chiasmus-plan <rank|safe|slice|seed-parity|track|audit|refresh> --facts FILE [options]"
        output.puts "  rank               Rank symbols by importance"
        output.puts "  safe               Rank symbols by safety"
        output.puts "  slice              Group symbols into branch-sized worksets"
        output.puts "  seed-parity        Draft a Markdown parity roadmap"
        output.puts "  track              Merge generated slices with curated status"
        output.puts "  audit              Explain why a symbol was ranked the way it was"
        output.puts "  refresh            Highlight only slices changed since previous facts"
        output.puts "  --facts FILE       Path to facts emitted by chiasmus-facts"
        output.puts "  --format FORMAT    tsv|json"
        output.puts "  --inventory FILE   Path to curated parity inventory TSV"
        output.puts "  --out FILE         Write Markdown seed output to FILE"
        output.puts "  --parity-plan FILE Path to curated parity Markdown plan"
        output.puts "  --previous-facts FILE Path to previous facts snapshot for refresh"
        output.puts "  --symbol NAME      Symbol to audit"
        output.puts "  --top N            Limit output rows"
        output.puts "  --entry-point NAME Override entry points from the facts file"
        0
      end

      private def invalid_mode(mode : String, error : IO) : Int32
        error.puts "Unknown mode: #{mode}"
        error.puts "Use 'rank', 'safe', 'slice', 'seed-parity', 'track', 'audit', or 'refresh'."
        1
      end
    end
  end
end
