require "crig"
require "../solvers/types"
require "../solvers/factory"
require "../solvers/correction_loop"
require "../skills/types"
require "../skills/library"

module Chiasmus
  module Formalize
    record AsyncResult(T),
      value : T? = nil,
      error : String? = nil

    # Result of formalize() — template + instructions for the calling LLM
    record FormalizeResult,
      template : Skills::SkillTemplate,
      instructions : String

    # Result of solve() — includes solver result + correction history
    record SolveResult,
      result : Solvers::SolverResult,
      # Whether the correction loop terminated cleanly — i.e. the solver returned
      # a non-error result (sat / unsat / unknown / success) rather than erroring
      # out or exhausting its rounds. This is NOT a verdict on the property:
      # `converged: true` with `result.status: "unsat"` means "the solver ran and
      # found no counterexample in the given model", which is not a proof. Read
      # `result.status` for the actual answer.
      converged : Bool,
      rounds : Int32,
      history : Array(Solvers::CorrectionAttempt),
      template_used : String?,
      # Convenience: extracted answers for Prolog results
      answers : Array(Solvers::PrologAnswer)

    # Embedding function: takes an array of texts (problem + template search texts)
    # and returns corresponding vector embeddings.
    alias EmbedFn = Array(String) -> Array(Array(Float64))

    FORMALIZE_SYSTEM = <<-TEXT
    Formalization engine. Translate natural language → formal logic.

    Template = starting point. Fill slots, but adapt structure if needed. Add/remove variables, assertions, rules.
    Output ONLY complete spec. No explanation, no markdown fences.

    ⚠ SLOT format examples and the EXAMPLE block illustrate FORM/SYNTAX only — never copy their concrete
    values (roles, actions, resources, predicates, etc.) into your output. Model EXACTLY AND ONLY the
    entities, values, and rules stated in the PROBLEM. Never introduce content the problem doesn't mention.

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
      @@before_formalize_async_result_send_hook : Proc(Nil)? = nil
      @@before_solve_async_result_send_hook : Proc(Nil)? = nil

      @library : Skills::Library
      @agent : Crig::Agent(M)
      @embedding : EmbedFn?

      def initialize(@library : Skills::Library, @agent : Crig::Agent(M), @embedding : EmbedFn? = nil)
      end

      # Formalize a problem: select a template and return it with
      # fill instructions. Does NOT execute or call the LLM for filling.
      #
      # When an embedding function is available, all templates are embedded
      # and re-ranked by cosine similarity to the problem. BM25 is the
      # fallback when no embedding is configured or embedding fails.
      def formalize(problem : String) : FormalizeResult?
        template = nil

        if embedding = @embedding
          template = select_by_embedding(problem, embedding)
        end

        # Fallback to BM25 when no embedding or embedding failed
        unless template
          results = @library.search(problem, Skills::SearchOptions.new(limit: 1))
          template = if results.empty?
                       first = @library.list.first?
                       return nil unless first
                       first.template
                     else
                       results.first.template
                     end
        end

        instructions = build_instructions(problem, template)
        FormalizeResult.new(template: template, instructions: instructions)
      end

      def formalize_async(problem : String) : Channel(AsyncResult(FormalizeResult))
        response = Channel(AsyncResult(FormalizeResult)).new(1)

        spawn do
          result = begin
            AsyncResult(FormalizeResult).new(value: formalize(problem))
          rescue ex
            AsyncResult(FormalizeResult).new(error: ex.message || ex.class.name)
          end

          @@before_formalize_async_result_send_hook.try(&.call)
          response.send(result)
        ensure
          response.close
        end

        response
      end

      # End-to-end solve: select template, ask LLM to fill slots,
      # submit to solver with correction loop.
      def solve(problem : String, max_rounds : Int32 = 5) : SolveResult
        formalize_result = formalize(problem)
        unless formalize_result
          return SolveResult.new(
            result: Solvers::ErrorResult.new("No matching template found — skill library is empty"),
            converged: false,
            rounds: 0,
            history: [] of Solvers::CorrectionAttempt,
            template_used: nil,
            answers: [] of Solvers::PrologAnswer,
          )
        end
        template = formalize_result.template

        # Ask LLM to fill the template
        filled_spec = llm_fill(problem, template)

        # Lint the filled spec
        linted_spec, lint_errors = lint_loop(filled_spec, template, max_rounds)
        unless lint_errors.empty?
          # If linting fails, ask LLM to fix it
          filled_spec = llm_fix_lint(filled_spec, lint_errors, template)
          linted_spec, lint_errors = lint_loop(filled_spec, template, max_rounds)
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
            linted, lint_errors = lint_loop(fixed, template, max_rounds)
            unless lint_errors.empty?
              # If linting fails, try to fix it
              fixed = llm_fix_lint(fixed, lint_errors, template)
              linted, _ = lint_loop(fixed, template, max_rounds)
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

      def solve_async(problem : String, max_rounds : Int32 = 5) : Channel(AsyncResult(SolveResult))
        response = Channel(AsyncResult(SolveResult)).new(1)

        spawn do
          result = begin
            AsyncResult(SolveResult).new(value: solve(problem, max_rounds))
          rescue ex
            AsyncResult(SolveResult).new(error: ex.message || ex.class.name)
          end

          @@before_solve_async_result_send_hook.try(&.call)
          response.send(result)
        ensure
          response.close
        end

        response
      end

      def self.set_before_formalize_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_formalize_async_result_send_hook = block
      end

      def self.clear_before_formalize_async_result_send_hook_for_test : Nil
        @@before_formalize_async_result_send_hook = nil
      end

      def self.set_before_solve_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_solve_async_result_send_hook = block
      end

      def self.clear_before_solve_async_result_send_hook_for_test : Nil
        @@before_solve_async_result_send_hook = nil
      end

      # Use embedding-based cosine similarity to select the best template.
      # Returns nil on any failure so the caller can fall back to BM25.
      private def select_by_embedding(problem : String, embedding : EmbedFn) : Skills::SkillTemplate?
        all = @library.list
        return nil if all.empty?

        texts = all.map { |skill| @library.get_template_search_text(skill.template) }
        vectors = embedding.call([problem] + texts)

        query_vec = vectors[0]
        template_vecs = vectors[1..]

        q_norm = l2_norm(query_vec)
        return nil if q_norm == 0.0

        best_idx = -1
        best_score = -Float64::INFINITY
        template_vecs.each_with_index do |t_vec, i|
          t_norm = l2_norm(t_vec)
          next if t_norm == 0.0
          dot = 0.0
          query_vec.each_with_index { |query_value, index| dot += t_vec[index] * query_value }
          score = dot / (q_norm * t_norm)
          if score > best_score
            best_score = score
            best_idx = i
          end
        end

        return nil if best_idx < 0
        all[best_idx].template
      rescue
        nil
      end

      private def l2_norm(v : Array(Float64)) : Float64
        sum = 0.0
        v.each { |value| sum += value * value }
        Math.sqrt(sum)
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
                           "\n⚠ TIPS:\n" + tips.map { |tip| "  #{tip}" }.join("\n")
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

        response = @agent.prompt("#{FORMALIZE_SYSTEM}\n\n#{instructions}").send_async.receive.unwrap

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
        ).send_async.receive.unwrap

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
        ).send_async.receive.unwrap

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

          (lines.size - 1).downto(0) do |line_index|
            trimmed = lines[line_index].strip
            if trimmed.starts_with?("?-")
              query = trimmed.lchop("?-").strip
              program = lines[0...line_index].join("\n").strip
              break
            end
          end

          Solvers::PrologSolverInput.new(program: program, query: query)
        end
      end

      # Strip markdown fences and trim whitespace from LLM output
      private def clean_response(response : String) : String
        response
          .gsub(/^```(?:smt-lib|smtlib|smt|prolog|pl)?\n?/m, "")
          .gsub(/^```\n?/m, "")
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
          if (error.includes?("clause") && error.includes?("period")) && solver == Solvers::SolverType::Prolog
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
