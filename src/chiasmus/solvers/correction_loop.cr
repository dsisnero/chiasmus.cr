require "./factory"

module Chiasmus
  module Solvers
    class CorrectionLoopOptions
      property max_rounds : Int32

      def initialize(@max_rounds = 5)
      end
    end

    # Run a bounded correction loop: submit spec to solver, if it errors
    # call the fixer to patch it, resubmit, repeat up to max_rounds.
    #
    # The loop stops when:
    # - The solver returns a non-error result (sat/unsat/unknown/success) → converged
    # - The fixer returns null (gives up) → not converged
    # - Max rounds reached → not converged
    def self.correction_loop(
      initial_input : SolverInput,
      fixer : SpecFixer,
      options : CorrectionLoopOptions = CorrectionLoopOptions.new,
    ) : CorrectionResult
      history = [] of CorrectionAttempt
      current_input = initial_input

      options.max_rounds.times do |round|
        solver = Factory.build(current_input)
        result = begin
          solver.solve(current_input)
        ensure
          solver.dispose
        end

        # Record attempt
        attempt = CorrectionAttempt.new(
          input: current_input,
          result: result,
          error: result.is_a?(ErrorResult) ? result.error : nil
        )
        history << attempt

        # Check if we've converged (non-error result)
        unless result.is_a?(ErrorResult)
          return CorrectionResult.new(
            result: result,
            converged: true,
            rounds: round + 1,
            history: history
          )
        end

        # Ask fixer to patch the spec
        fixed_input = fixer.call(attempt, result.error, round, result, current_input)
        break unless fixed_input # fixer gave up

        current_input = fixed_input
      end

      # Max rounds reached without convergence
      CorrectionResult.new(
        result: history.last.result || ErrorResult.new(error: "Correction loop failed"),
        converged: false,
        rounds: history.size,
        history: history
      )
    end
  end
end
