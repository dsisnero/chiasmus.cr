module Chiasmus
  module Graph
    module Facts
      extend self

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
        lines = [] of String

        lines << ":- dynamic(defines/5)."
        lines << ":- dynamic(calls/2)."
        lines << ":- dynamic(imports/3)."
        lines << ":- dynamic(exports/2)."
        lines << ":- dynamic(contains/2)."
        lines << ":- dynamic(entry_point/1)."
        lines << ""

        graph.defines.each do |fact|
          lines << "defines(#{escape_atom(fact.file)}, #{escape_atom(fact.name)}, #{escape_atom(fact.kind.to_prolog_atom)}, #{fact.line}, #{fact.end_line})."
        end
        lines << "" unless graph.defines.empty?

        graph.calls.each do |fact|
          lines << "calls(#{escape_atom(fact.caller)}, #{escape_atom(fact.callee)})."
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

        effective_entry_points = entry_points || graph.exports.map(&.name).uniq!
        effective_entry_points.each do |entry_point|
          lines << "entry_point(#{escape_atom(entry_point)})."
        end

        lines << ""
        emit_insight_facts(graph, lines) if include_insights
        lines << BUILTIN_RULES
        lines.join("\n")
      end

      private def emit_insight_facts(graph : CodeGraph, lines : Array(String)) : Nil
        # Run three independent analyses concurrently via spawn + Channel
        comm_chan = Channel(Array(Community)?).new(1)
        hub_chan = Channel(Array(Hub)?).new(1)
        bridge_chan = Channel(Array(Bridge)?).new(1)

        spawn { comm_chan.send(CommunityDetection.detect(graph)) }
        spawn { hub_chan.send(Insights.detect_hubs(graph)) }
        spawn { bridge_chan.send(Insights.detect_bridges(graph)) }

        communities = comm_chan.receive
        hubs = hub_chan.receive
        bridges = bridge_chan.receive

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
