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
        dead(Name) :- defines(_, Name, function, _), \\+ calls(_, Name), \\+ entry_point(Name).

        % Convenience predicates
        caller_of(Target, Caller) :- calls(Caller, Target).
        callee_of(Source, Callee) :- calls(Source, Callee).
      PROLOG

      def escape_atom(value : String) : String
        return value if value.matches?(/^[a-z][a-z0-9_]*$/)

        "'#{value.gsub("'", "''")}'"
      end

      def graph_to_prolog(graph : CodeGraph, entry_points : Array(String)? = nil) : String
        lines = [] of String

        lines << ":- dynamic(defines/4)."
        lines << ":- dynamic(calls/2)."
        lines << ":- dynamic(imports/3)."
        lines << ":- dynamic(exports/2)."
        lines << ":- dynamic(contains/2)."
        lines << ":- dynamic(entry_point/1)."
        lines << ""

        graph.defines.each do |fact|
          lines << "defines(#{escape_atom(fact.file)}, #{escape_atom(fact.name)}, #{escape_atom(fact.kind.to_prolog_atom)}, #{fact.line})."
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

        effective_entry_points = entry_points || graph.exports.map(&.name).uniq
        effective_entry_points.each do |entry_point|
          lines << "entry_point(#{escape_atom(entry_point)})."
        end

        lines << ""
        lines << BUILTIN_RULES
        lines.join("\n")
      end
    end
  end
end
