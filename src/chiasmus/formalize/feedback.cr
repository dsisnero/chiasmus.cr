module Chiasmus
  module Formalize
    # Classify solver output into actionable repair feedback for the LLM.
    def self.classify_feedback(result : Solvers::SolverResult) : String
      case result
      when Solvers::ErrorResult
        "Solver error: #{result.error}"
      when Solvers::UnsatResult
        classify_unsat_feedback(result)
      when Solvers::SatResult
        classify_sat_feedback(result)
      when Solvers::SuccessResult
        classify_prolog_feedback(result)
      when Solvers::UnknownResult
        "Solver returned UNKNOWN — the problem may be too complex or outside the solver's decidable fragment. Try simplifying constraints."
      else
        "Unknown solver result"
      end
    end

    private def self.classify_unsat_feedback(result : Solvers::UnsatResult) : String
      unsat_core = result.unsat_core
      return generic_unsat_feedback if unsat_core.nil? || unsat_core.empty?

      core_list = unsat_core.map { |core_item| "  - #{core_item}" }.join("\n")
      "UNSAT — these assertions conflict:\n#{core_list}\nThe specification is over-constrained. Remove or weaken one of the conflicting assertions."
    end

    private def self.classify_sat_feedback(result : Solvers::SatResult) : String
      return "SAT — the constraints are satisfiable (trivially, no variables)." if result.model.empty?

      model_str = result.model.map { |k, v| "#{k} = #{v}" }.join(", ")
      "SAT — the solver found a satisfying assignment: #{model_str}. If this was unexpected, the spec may be under-constrained."
    end

    private def self.classify_prolog_feedback(result : Solvers::SuccessResult) : String
      return "No Prolog solutions found. Check if facts and rules cover the query pattern. Verify clause heads match." if result.answers.empty?

      ans_str = result.answers.first(5).map(&.formatted).join("; ")
      suffix = result.answers.size > 5 ? " (and #{result.answers.size - 5} more)" : ""
      "Prolog found #{result.answers.size} answer(s): #{ans_str}#{suffix}"
    end

    private def self.generic_unsat_feedback : String
      "UNSAT — the constraints are contradictory. The specification is over-constrained."
    end
  end
end
