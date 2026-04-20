require "./types"
require "./z3_solver"
require "./prolog_solver"

module Chiasmus
  module Solvers
    module Factory
      extend self

      def build(type : SolverType) : Solver
        case type
        when SolverType::Z3
          Z3Solver.new
        when SolverType::Prolog
          PrologSolver.new
        else
          raise "Unsupported solver type: #{type}"
        end
      end

      def build(input : SolverInput) : Solver
        build(input.type)
      end
    end
  end
end
