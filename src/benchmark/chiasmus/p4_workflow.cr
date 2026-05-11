require "../../chiasmus/solvers/prolog_solver"

module Benchmark
  module Chiasmus
    record WorkflowResult, unreachable_states : Array(String), dead_end_states : Array(String)

    def self.solve_workflow(input : NamedTuple(
                              initial: String,
                              states: Array(String),
                              transitions: Array(NamedTuple(from: String, to: String, action: String)),
                            )) : WorkflowResult
      solver = ::Chiasmus::Solvers::PrologSolver.new

      transition_facts = input[:transitions].map { |transition| "transition(#{transition[:from]}, #{transition[:to]})." }.join("\n")

      program = <<-PROLOG
#{transition_facts}
has_outgoing(X) :- transition(X, _).
PROLOG

      reachable = Set(String).new.add(input[:initial])
      frontier = [input[:initial]]

      while frontier.size > 0
        current = frontier.pop
        result = solver.solve(program, "transition(#{current}, X).")
        case result
        when ::Chiasmus::Solvers::SuccessResult
          result.answers.each do |ans|
            next_state = ans.bindings["X"]?
            if next_state && !reachable.includes?(next_state)
              reachable.add(next_state)
              frontier << next_state
            end
          end
        end
      end

      has_outgoing = Set(String).new
      out_result = solver.solve(program, "has_outgoing(X).")
      case out_result
      when ::Chiasmus::Solvers::SuccessResult
        out_result.answers.each do |ans|
          state = ans.bindings["X"]?
          has_outgoing.add(state) if state
        end
      end

      unreachable_states = input[:states].reject { |state| reachable.includes?(state) }
      dead_end_states = input[:states].select do |state|
        reachable.includes?(state) && !has_outgoing.includes?(state) && state != input[:initial]
      end

      WorkflowResult.new(unreachable_states: unreachable_states, dead_end_states: dead_end_states)
    end
  end
end
