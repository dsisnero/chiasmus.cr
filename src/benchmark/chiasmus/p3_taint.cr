require "../../chiasmus/solvers/prolog_solver"

module Benchmark
  module Chiasmus
    record TaintResult, reachable : Array({source: String, sink: String}), unreachable : Array(String)

    def self.solve_taint(input : NamedTuple(
                           edges: Array(NamedTuple(from: String, to: String)),
                           sources: Array(String),
                           sinks: Array(String),
                         )) : TaintResult
      solver = ::Chiasmus::Solvers::PrologSolver.new

      edge_facts = input[:edges].map { |e| "edge(#{e[:from]}, #{e[:to]})." }.join("\n")

      program = <<-PROLOG
#{edge_facts}
reaches(A, B) :- edge(A, B).
reaches(A, B) :- edge(A, Mid), reaches(Mid, B).
PROLOG

      reachable = [] of {source: String, sink: String}
      unreachable = [] of String

      input[:sources].each do |source|
        input[:sinks].each do |sink|
          result = solver.solve(program, "reaches(#{source}, #{sink}).")
          case result
          when ::Chiasmus::Solvers::SuccessResult
            if result.answers.size > 0
              reachable << {source: source, sink: sink}
            else
              unreachable << sink
            end
          else
            unreachable << sink
          end
        end
      end

      TaintResult.new(reachable: reachable, unreachable: unreachable)
    end
  end
end
