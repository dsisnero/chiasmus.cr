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

    class Engine(M)
      @library : Skills::Library
      @agent : Crig::Agent(M)

      def initialize(@library : Skills::Library, @agent : Crig::Agent(M))
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

        # Lint the filled spec
        linted_spec, lint_errors = lint_loop(filled_spec, template, 2)
        unless lint_errors.empty?
          # If linting fails, ask LLM to fix it
          filled_spec = llm_fix_lint(filled_spec, lint_errors, template)
          linted_spec, lint_errors = lint_loop(filled_spec, template, 2)
        end

        # Build solver input
        initial_input = build_solver_input(template, linted_spec)

        # Run correction loop with LLM as fixer
        correction_result = Solvers.correction_loop(
          initial_input,
          ->(attempt : Solvers::CorrectionAttempt, error : String, _round : Int32, result : Solvers::SolverResult?, _previous_input : Solvers::SolverInput?) : Solvers::SolverInput? do
            feedback = if result
                         Formalize.classify_feedback(result)
                       else
                         error
                       end

            fixed = llm_fix(attempt.input, feedback, template)
            # Lint the fix before resubmitting to the solver
            linted, lint_errors = lint_loop(fixed, template, 2)
            unless lint_errors.empty?
              # If linting fails, try to fix it
              fixed = llm_fix_lint(fixed, lint_errors, template)
              linted, _ = lint_loop(fixed, template, 2)
            end

            build_solver_input(template, linted).as(Solvers::SolverInput?)
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
          answers: correction_result.result.is_a?(Solvers::SuccessResult) ? correction_result.result.as(Solvers::SuccessResult).answers : [] of Solvers::PrologAnswer
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

        tips_section = if tips = template.tips
                         if !tips.empty?
                           "\nTemplate-specific tips:\n" + tips.join("\n")
                         else
                           ""
                         end
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

        response = @agent.prompt("#{FORMALIZE_SYSTEM}\n\n#{instructions}").send

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

        response = @agent.prompt(
          <<-CONTENT
          #{FIX_SYSTEM}

          SOLVER: #{template.solver}
          SPECIFICATION:
          #{spec}

          FEEDBACK:
          #{feedback}

          Fix the specification and return only the corrected version.
          CONTENT
        ).send

        clean_response(response)
      end

      private def llm_fix_lint(
        spec : String,
        lint_errors : Array(String),
        template : Skills::SkillTemplate,
      ) : String
        response = @agent.prompt(
          <<-CONTENT
          #{FIX_SYSTEM}

          SOLVER: #{template.solver}
          SPECIFICATION:
          #{spec}

          LINT ERRORS:
          #{lint_errors.join("\n")}

          Fix the specification to resolve these lint errors and return only the corrected version.
          CONTENT
        ).send

        clean_response(response)
      end

      private def build_solver_input(template : Skills::SkillTemplate, spec : String) : Solvers::SolverInput?
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

      # Lint a spec, applying auto-fixes and reporting errors.
      # Returns the linted spec and any remaining errors.
      private def lint_loop(spec : String, template : Skills::SkillTemplate, max_rounds : Int32) : {String, Array(String)}
        current = spec
        errors = [] of String

        max_rounds.times do |round|
          lint_result = Formalize.lint_spec(current, template.solver)
          current = lint_result.spec

          if lint_result.errors.empty?
            return {current, [] of String}
          end

          # If we have errors and this is the first round, try to fix common issues
          if round == 0
            # Try to apply some heuristic fixes
            fixed = try_heuristic_fixes(current, lint_result.errors, template.solver)
            if fixed != current
              current = fixed
              next
            end
          end

          errors = lint_result.errors
          break
        end

        {current, errors}
      end

      private def try_heuristic_fixes(spec : String, errors : Array(String), solver : Solvers::SolverType) : String
        fixed = spec

        errors.each do |error|
          # Try to fix missing periods in Prolog
          if error.includes?("No clauses ending with a period") && solver == Solvers::SolverType::Prolog
            # Add period to last line if missing
            lines = fixed.lines
            if !lines.empty? && !lines.last.strip.ends_with?('.')
              lines[-1] = "#{lines.last.strip}."
              fixed = lines.join("\n")
            end
          end

          # Try to fix unbalanced parentheses
          if error.includes?("Unbalanced parentheses")
            # Simple heuristic: add missing closing parens at end
            depth = 0
            fixed.each_char do |char|
              depth += 1 if char == '('
              depth -= 1 if char == ')'
            end
            if depth > 0
              fixed = "#{fixed}#{")" * depth}"
            end
          end
        end

        fixed
      end
    end
  end
end
