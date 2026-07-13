require "./ir"
require "./community"
require "./insights"

module Chiasmus
  module Graph
    module Facts
      extend self

      alias ScopedCallCandidate = NamedTuple(
        file: String,
        caller: String,
        callee: String,
        callee_file: String,
        caller_is_unique: Bool,
      )

      BUILTIN_RULES = <<-PROLOG.strip
        % List membership (not built-in in Tau Prolog without lists module)
        member(X, [X|_]).
        member(X, [_|T]) :- member(X, T).

        % Cycle-safe reachability via visited list
        reaches(A, B) :- reaches(A, B, [A]).
        reaches(A, B, _) :- calls(A, B).
        reaches(A, B, Visited) :- calls(A, Mid), \\+ member(Mid, Visited), reaches(Mid, B, [Mid|Visited]).

        % Path finding (returns the call chain)
        path(A, B, Path) :- path(A, B, [A], Path).
        path(A, B, _, [A, B]) :- calls(A, B).
        path(A, B, Visited, [A|Rest]) :- calls(A, Mid), \\+ member(Mid, Visited), path(Mid, B, [Mid|Visited], Rest).

        % Dead code: defined function not called by anyone and not an entry point
        dead(Name) :- defines(_, Name, function, _, _), \\+ calls(_, Name), \\+ entry_point(Name).

        % Convenience predicates
        caller_of(Target, Caller) :- calls(Caller, Target).
        callee_of(Source, Callee) :- calls(Source, Callee).
      PROLOG

      def escape_atom(value : String) : String
        return value if value.matches?(/^[a-z][a-z0-9_]*$/)

        "'#{value.gsub("'", "''")}'"
      end

      def graph_to_prolog(graph : CodeGraph, entry_points : Array(String)? = nil, include_insights : Bool = false) : String
        normalized = IR.normalize(graph)
        render_prolog(IR::Lowering.to_code_graph(normalized), entry_points, include_insights, normalized)
      end

      def graph_to_prolog(graph : IR::SemanticGraph, entry_points : Array(String)? = nil, include_insights : Bool = false) : String
        normalized = IR.normalize(graph)
        render_prolog(IR::Lowering.to_code_graph(normalized), entry_points, include_insights, normalized)
      end

      private def render_prolog(
        graph : CodeGraph,
        entry_points : Array(String)? = nil,
        include_insights : Bool = false,
        semantic_graph : IR::SemanticGraph? = nil,
      ) : String
        lines = [] of String
        effective_entry_points = entry_points || graph.exports.map(&.name).uniq!
        entry_point_files = resolve_entry_point_files(graph, effective_entry_points)

        lines << ":- dynamic(defines/5)."
        lines << ":- dynamic(calls/2)."
        lines << ":- dynamic(calls_in/3)."
        lines << ":- dynamic(imports/3)."
        lines << ":- dynamic(exports/2)."
        lines << ":- dynamic(contains/2)."
        lines << ":- dynamic(entry_point/1)."
        lines << ":- dynamic(entry_point_file/2)."
        lines << ""

        graph.defines.each do |fact|
          span = fact.span
          lines << "defines(#{escape_atom(fact.file)}, #{escape_atom(fact.name)}, #{escape_atom(fact.kind.to_prolog_atom)}, #{span.start_line}, #{span.end_line})."
        end
        lines << "" unless graph.defines.empty?

        graph.calls.each do |fact|
          lines << "calls(#{escape_atom(fact.caller)}, #{escape_atom(fact.callee)})."
        end
        semantic_graph.try do |semantic|
          resolve_scoped_calls(semantic, entry_point_files).each do |file, caller, callee|
            lines << "calls_in(#{escape_atom(file)}, #{escape_atom(caller)}, #{escape_atom(callee)})."
          end
        end
        lines << "" unless graph.calls.empty?

        graph.imports.each do |fact|
          lines << "imports(#{escape_atom(fact.file)}, #{escape_atom(fact.name)}, #{escape_atom(fact.source)})."
        end
        lines << "" unless graph.imports.empty?

        graph.exports.each do |fact|
          lines << "exports(#{escape_atom(fact.file)}, #{escape_atom(fact.name)})."
        end
        lines << "" unless graph.exports.empty?

        graph.contains.each do |fact|
          lines << "contains(#{escape_atom(fact.parent)}, #{escape_atom(fact.child)})."
        end
        lines << "" unless graph.contains.empty?

        effective_entry_points.each do |entry_point|
          lines << "entry_point(#{escape_atom(entry_point)})."
        end
        entry_point_files.each do |file, entry_point|
          lines << "entry_point_file(#{escape_atom(file)}, #{escape_atom(entry_point)})."
        end

        lines << ""
        emit_insight_facts(graph, lines) if include_insights
        lines << BUILTIN_RULES
        lines.join("\n")
      end

      private def resolve_entry_point_files(graph : CodeGraph, entry_points : Array(String)) : Array(Tuple(String, String))
        resolved = [] of Tuple(String, String)

        entry_points.each do |entry_point|
          export_matches = graph.exports.select { |fact| fact.name == entry_point }
          if export_matches.empty?
            define_matches = graph.defines.select { |fact| fact.name == entry_point }
            if define_matches.size == 1
              resolved << {define_matches.first.file, entry_point}
            end
            next
          end

          export_matches.each do |fact|
            resolved << {fact.file, entry_point}
          end
        end

        resolved.uniq
      end

      private def resolve_scoped_calls(
        graph : IR::SemanticGraph,
        entry_point_files : Array(Tuple(String, String)),
      ) : Array(Tuple(String, String, String))
        index = IR::ScopedSymbolIndex.new(graph.symbols)
        candidates = [] of ScopedCallCandidate

        graph.calls.each do |edge|
          callers = index.symbols_named(edge.caller)
          caller_is_unique = callers.size == 1

          callers.each do |caller|
            callee = resolve_scoped_callee(index, edge.callee, caller.file, edge.callee_qn, caller_is_unique)
            next unless callee

            candidates << {
              file:             caller.file,
              caller:           edge.caller,
              callee:           edge.callee,
              callee_file:      callee.file,
              caller_is_unique: caller_is_unique,
            }
          end
        end

        reachable_callers = resolve_reachable_scoped_callers(index, candidates, entry_point_files)
        resolved = candidates
          .select { |candidate| candidate[:caller_is_unique] || reachable_callers.includes?({candidate[:file], candidate[:caller]}) }
          .map { |candidate| {candidate[:file], candidate[:caller], candidate[:callee]} }
        resolved.uniq!
        resolved
      end

      private def resolve_reachable_scoped_callers(
        index : IR::ScopedSymbolIndex,
        candidates : Array(ScopedCallCandidate),
        entry_point_files : Array(Tuple(String, String)),
      ) : Set(Tuple(String, String))
        by_caller = Hash(Tuple(String, String), Array(ScopedCallCandidate)).new do |hash, key|
          hash[key] = [] of ScopedCallCandidate
        end
        candidates.each do |candidate|
          by_caller[{candidate[:file], candidate[:caller]}] << candidate
        end

        reachable = Set(Tuple(String, String)).new
        queue = [] of Tuple(String, String)

        entry_point_files.each do |file, name|
          index.symbols_in_file(file, name).each do |symbol|
            key = {symbol.file, symbol.qualified_name}
            next unless reachable.add?(key)

            queue << key
          end
        end

        until queue.empty?
          current = queue.shift
          by_caller[current]?.try &.each do |candidate|
            callee_key = {candidate[:callee_file], candidate[:callee]}
            next unless reachable.add?(callee_key)

            queue << callee_key
          end
        end

        reachable
      end

      private def resolve_scoped_callee(
        index : IR::ScopedSymbolIndex,
        qualified_name : String,
        file : String,
        expected_qn : String?,
        caller_is_unique : Bool,
      ) : IR::SymbolNode?
        local_matches = index.symbols_in_file(file, qualified_name)
        local_matches = local_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
        return local_matches.first if local_matches.size == 1
        return nil unless caller_is_unique

        global_matches = index.symbols_named(qualified_name)
        global_matches = global_matches.select { |symbol| symbol.qualified_name == expected_qn } if expected_qn
        return global_matches.first if global_matches.size == 1

        nil
      end

      private def emit_insight_facts(graph : CodeGraph, lines : Array(String)) : Nil
        # These analyses are CPU-bound under the default runtime, so keep the
        # code path sequential until we have a measured parallel implementation.
        communities = CommunityDetection.detect(graph)
        hubs = Insights.detect_hubs(graph)
        bridges = Insights.detect_bridges(graph)

        if communities && !communities.empty?
          communities.each do |community|
            lines << "cohesion(#{community.id}, #{community.cohesion})."
            community.members.each do |member|
              lines << "community(#{escape_atom(member)}, #{community.id})."
            end
          end
          lines << ""
        end

        if hubs && !hubs.empty?
          hubs.each do |hub|
            lines << "hub(#{escape_atom(hub.name)}, #{hub.degree})."
          end
          lines << ""
        end

        if bridges && !bridges.empty?
          bridges.each do |bridge|
            lines << "bridge(#{escape_atom(bridge.name)}, #{bridge.score})."
          end
          lines << ""
        end
      end
    end
  end
end
