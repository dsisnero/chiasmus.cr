module Chiasmus
  module Formalize
    # Result of formalize() — template + instructions for the calling LLM
    record FormalizeResult,
      template : Skills::SkillTemplate,
      instructions : String

    # Result of solve() — includes solver result + correction history
    record SolveResult,
      result : Solvers::SolverResult,
      converged : Bool,
      rounds : Int32,
      history : Array(Solvers::CorrectionAttempt),
      template_used : String?,
      # Convenience: extracted answers for Prolog results
      answers : Array(Solvers::PrologAnswer)

    FORMALIZE_SYSTEM = <<-TEXT
    Formalization engine. Translate natural language → formal logic.

    Template = starting point. Fill slots, but adapt structure if needed. Add/remove variables, assertions, rules.
    Output ONLY complete spec. No explanation, no markdown fences.

    Z3: valid SMT-LIB. No (check-sat)/(get-model). Use (= flag (or ...)) not (=> ... flag).
    Prolog: valid ISO Prolog. All clauses end with period.

    Precise syntax — spec goes directly to solver.
    TEXT

    FIX_SYSTEM = <<-TEXT
    Fix failed formal spec. Return ONLY corrected spec. No explanation, no fences.

    Common fixes by feedback type:
    - Solver error: type mismatches → matching types | missing declarations → declare before use | unbalanced parens | Prolog missing periods
    - UNSAT with core: conflicting assertions identified → remove or weaken one of the conflicting constraints
    - No Prolog solutions: missing facts/rules → add covering clauses | wrong query pattern → fix unification
    TEXT

    class Engine
      @library : Skills::Library
      @llm : LLM::Adapter

      def initialize(@library : Skills::Library, @llm : LLM::Adapter)
      end

      # Formalize a problem: select a template and return it with
      # fill instructions. Does NOT execute or call the LLM for filling.
      def formalize(problem : String) : FormalizeResult
        results = @library.search(problem, Skills::SearchOptions.new(limit: 1))
        template = if results.empty?
                     @library.list.first.template # fallback to first template
                   else
                     results.first.template
                   end

        instructions = build_instructions(problem, template)
        FormalizeResult.new(template: template, instructions: instructions)
      end

      # End-to-end solve: select template, ask LLM to fill slots,
      # submit to solver with correction loop.
      def solve(problem : String, max_rounds : Int32 = 5) : SolveResult
        formalize_result = formalize(problem)
        template = formalize_result.template

        # Ask LLM to fill the template
        filled_spec = llm_fill(problem, template)

        # TODO: Implement lint loop
        # filled_spec = lint_loop(filled_spec, template, max_rounds)

        # Build solver input
        initial_input = build_solver_input(template, filled_spec)

        # Run correction loop with LLM as fixer
        correction_result = Solvers.correction_loop(
          initial_input,
          ->(attempt : Solvers::CorrectionAttempt, error : String, _round : Int32, result : Solvers::SolverResult?) do
            feedback = if result
                         classify_feedback(result)
                       else
                         error
                       end

            fixed = llm_fix(attempt.input, feedback, template)
            # TODO: Lint the fix before resubmitting to the solver
            # linted = lint_loop(fixed, template, 2)
            linted = fixed

            build_solver_input(template, linted)
          end,
          Solvers::CorrectionLoopOptions.new(max_rounds: max_rounds)
        )

        # Record template use
        @library.record_use(template.name, correction_result.converged)

        SolveResult.new(
          result: correction_result.result,
          converged: correction_result.converged,
          rounds: correction_result.rounds,
          history: correction_result.history,
          template_used: template.name,
          answers: correction_result.result.is_a?(Solvers::SuccessResult) ? correction_result.result.answers : [] of Solvers::PrologAnswer
        )
      end

      private def build_instructions(problem : String, template : Skills::SkillTemplate) : String
        slot_descs = template.slots.map do |slot|
          "  {{SLOT:#{slot.name}}} — #{slot.description}\n    Example: #{slot.format}"
        end.join("\n\n")

        # Find matching normalization guidance
        norm_guidance = template.normalizations.map do |norm|
          "  - #{norm.source}: #{norm.transform}"
        end.join("\n")

        query_note = template.solver == Solvers::SolverType::Prolog ? "\nAlso provide Prolog query goal (ending with period) for the question." : ""

        tips_section = if template.tips && !template.tips.empty?
                         "\n⚠ TIPS:\n#{template.tips.map { |t| "  #{t}" }.join("\n")}"
                       else
                         ""
                       end

        example_section = if template.example
                            "\nEXAMPLE (reference only — write your own):\n#{template.example}"
                          else
                            ""
                          end

        <<-INSTRUCTIONS
        #{template.name} (#{template.solver}) — #{template.signature}

        SKELETON:
        #{template.skeleton}

        SLOTS:
        #{slot_descs}

        NORMALIZE: #{norm_guidance}#{tips_section}#{example_section}#{query_note}

        PROBLEM: #{problem}

        Fill {{SLOT:name}} markers. Template = starting point — adapt if needed. Add/remove parts freely.
        #{template.solver == Solvers::SolverType::Z3 ? "No (check-sat)/(get-model)." : "All clauses end with period."}
        Output ONLY filled spec.
        INSTRUCTIONS
      end

      private def llm_fill(problem : String, template : Skills::SkillTemplate) : String
        instructions = build_instructions(problem, template)

        response = @llm.complete(FORMALIZE_SYSTEM, [
          LLM::LLMMessage.new(role: "user", content: instructions),
        ])

        clean_response(response)
      end

      private def llm_fix(
        attempt : Solvers::SolverInput,
        feedback : String,
        template : Skills::SkillTemplate,
      ) : String
        spec = case attempt
               when Solvers::Z3SolverInput
                 attempt.smtlib
               when Solvers::PrologSolverInput
                 attempt.program
               else
                 ""
               end

        response = @llm.complete(FIX_SYSTEM, [
          LLM::LLMMessage.new(
            role: "user",
            content: <<-CONTENT
            SOLVER: #{template.solver}
            SPECIFICATION:
            #{spec}

            FEEDBACK:
            #{feedback}

            Fix the specification and return only the corrected version.
            CONTENT
          ),
        ])

        clean_response(response)
      end

      private def build_solver_input(template : Skills::SkillTemplate, spec : String) : Solvers::SolverInput
        if template.solver == Solvers::SolverType::Z3
          Solvers::Z3SolverInput.new(smtlib: spec)
        else
          # For Prolog, extract ?- query from the last line that starts with ?-
          lines = spec.split("\n")
          program = spec
          query = "true."

          (lines.size - 1).downto(0) do |i|
            trimmed = lines[i].strip
            if trimmed.starts_with?("?-")
              query = trimmed.lchop("?-").strip
              program = lines[0...i].join("\n").strip
              break
            end
          end

          Solvers::PrologSolverInput.new(program: program, query: query)
        end
      end

      # Strip markdown fences and trim whitespace from LLM output
      private def clean_response(response : String) : String
        response
          .gsub(/^```(?:smt-lib|smtlib|smt|prolog|pl)?\n?/, "")
          .gsub(/^```\n?/, "")
          .strip
      end

      # Classify a SolverResult into a human-readable feedback string
      # for the correction loop. This helps the LLM understand what went
      # wrong and how to fix it.
      private def classify_feedback(result : Solvers::SolverResult) : String
        case result
        when Solvers::ErrorResult
          "Solver error: #{result.error}"
        when Solvers::UnsatResult
          if result.unsat_core && !result.unsat_core.empty?
            core_list = result.unsat_core.map { |c| "  - #{c}" }.join("\n")
            "UNSAT — these assertions conflict:\n#{core_list}\nThe specification is over-constrained. Remove or weaken one of the conflicting assertions."
          else
            "UNSAT — the constraints are contradictory. The specification is over-constrained."
          end
        when Solvers::SatResult
          if result.model.empty?
            "SAT — the constraints are satisfiable (trivially, no variables)."
          else
            model_str = result.model.map { |k, v| "#{k} = #{v}" }.join(", ")
            "SAT — the solver found a satisfying assignment: #{model_str}. If this was unexpected, the spec may be under-constrained."
          end
        when Solvers::SuccessResult
          if result.answers.empty?
            "No Prolog solutions found. Check if facts and rules cover the query pattern. Verify clause heads match."
          else
            ans_str = result.answers.first(5).map(&.formatted).join("; ")
            suffix = result.answers.size > 5 ? " (and #{result.answers.size - 5} more)" : ""
            "Prolog found #{result.answers.size} answer(s): #{ans_str}#{suffix}"
          end
        when Solvers::UnknownResult
          "Solver returned UNKNOWN — the problem may be too complex or outside the solver's decidable fragment. Try simplifying constraints."
        else
          "Unknown solver result"
        end
      end
    end
  end
end
