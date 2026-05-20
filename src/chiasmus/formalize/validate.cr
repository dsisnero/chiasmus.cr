module Chiasmus
  module Formalize
    record LintResult,
      spec : String,
      fixes : Array(String),
      errors : Array(String)

    # Lint and auto-fix a specification before sending to the solver.
    # Fixes what it can, reports what it can't.
    def self.lint_spec(spec : String, solver : Solvers::SolverType) : LintResult
      fixes = [] of String
      errors = [] of String
      cleaned = spec

      # ── Auto-fixes (applied silently) ──────────────────────

      # Strip markdown fences
      fence_pattern = /^```(?:smt-lib|smtlib|smt2?|prolog|pl)?\s*\n?/m
      if cleaned =~ fence_pattern
        cleaned = cleaned.gsub(fence_pattern, "").gsub(/^```\s*$/m, "")
        fixes << "Stripped markdown code fences"
      end

      # Trim whitespace
      cleaned = cleaned.strip

      if cleaned.empty?
        errors << "Specification is empty after cleaning"
        return LintResult.new(spec: cleaned, fixes: fixes, errors: errors)
      end

      # Unfilled template slots — cannot auto-fix
      slot_matches = cleaned.scan(/\{\{SLOT:\w+\}\}/)
      if !slot_matches.empty?
        errors << "Unfilled template slots: #{slot_matches.map(&.[0]).join(", ")}"
      end

      if solver == Solvers::SolverType::Z3
        cleaned = lint_smtlib(cleaned, fixes, errors)
      else
        cleaned = lint_prolog(cleaned, fixes, errors)
      end

      LintResult.new(spec: cleaned, fixes: fixes, errors: errors)
    end

    private def self.lint_smtlib(spec : String, fixes : Array(String), errors : Array(String)) : String
      cleaned = apply_smtlib_auto_fixes(spec, fixes)
      check_smtlib_parentheses(cleaned, errors)
      cleaned
    end

    private def self.apply_smtlib_auto_fixes(spec : String, fixes : Array(String)) : String
      cleaned = spec

      # Auto-fix: remove (check-sat) and (get-model)
      if cleaned =~ /\(\s*check-sat\s*\)/
        cleaned = cleaned.gsub(/\(\s*check-sat\s*\)/, "")
        fixes << "Removed (check-sat) — added automatically by the solver"
      end
      if cleaned =~ /\(\s*get-model\s*\)/
        cleaned = cleaned.gsub(/\(\s*get-model\s*\)/, "")
        fixes << "Removed (get-model) — added automatically by the solver"
      end
      if cleaned =~ /\(\s*exit\s*\)/
        cleaned = cleaned.gsub(/\(\s*exit\s*\)/, "")
        fixes << "Removed (exit)"
      end

      # Auto-fix: remove (set-logic ...) — our solver handles this
      if cleaned =~ /\(\s*set-logic\s+\w+\s*\)/
        cleaned = cleaned.gsub(/\(\s*set-logic\s+\w+\s*\)/, "")
        fixes << "Removed (set-logic) — solver selects logic automatically"
      end

      cleaned.strip
    end

    private def self.check_smtlib_parentheses(spec : String, errors : Array(String)) : Nil
      depth = 0
      i = 0
      while i < spec.size
        ch = spec[i]
        # Skip string literals
        if ch == '"'
          i = skip_string_literal(spec, i)
          next
        end
        # Skip line comments
        if ch == ';'
          i = skip_line_comment(spec, i)
          next
        end
        depth += 1 if ch == '('
        depth -= 1 if ch == ')'
        if depth < 0
          errors << "Unmatched closing parenthesis at position #{i}"
          break
        end
        i += 1
      end
      return unless depth > 0
      errors << "Unbalanced parentheses: #{depth} unclosed"
    end

    private def self.skip_string_literal(spec : String, start_index : Int32) : Int32
      i = start_index + 1
      while i < spec.size && spec[i] != '"'
        i += 1 if spec[i] == '\\'
        i += 1
      end
      i + 1
    end

    private def self.skip_line_comment(spec : String, start_index : Int32) : Int32
      i = start_index
      while i < spec.size && spec[i] != '\n'
        i += 1
      end
      i
    end

    # State-machine based Prolog comment/string stripper.
    # Handles % comments, /* */ comments, and proper quoting within single/double quotes.
    # Ported from vendor/chiasmus/src/formalize/validate.ts stripPrologNoise.
    private def self.strip_prolog_noise(src : String) : String
      out = String.build do |builder|
        i = 0
        n = src.size
        while i < n
          ch = src[i]

          # Line comment — only outside quotes
          if ch == '%'
            while i < n && src[i] != '\n'
              i += 1
            end
            next
          end

          # Block comment — only outside quotes
          if ch == '/' && src[i + 1]? == '*'
            i += 2
            while i < n && !(src[i]? == '*' && src[i + 1]? == '/')
              i += 1
            end
            i += 2
            next
          end

          # Single-quoted atom
          if ch == '\''
            i += 1
            while i < n
              if src[i]? == '\\' && i + 1 < n
                i += 2
                next
              end
              if src[i]? == '\'' && src[i + 1]? == '\''
                i += 2
                next
              end
              if src[i]? == '\''
                i += 1
                break
              end
              i += 1
            end
            builder << "''"
            next
          end

          # Double-quoted string
          if ch == '"'
            i += 1
            while i < n
              if src[i]? == '\\' && i + 1 < n
                i += 2
                next
              end
              if src[i]? == '"' && src[i + 1]? == '"'
                i += 2
                next
              end
              if src[i]? == '"'
                i += 1
                break
              end
              i += 1
            end
            builder << "\"\""
            next
          end

          builder << ch
          i += 1
        end
      end
      out
    end

    private def self.lint_prolog(spec : String, fixes : Array(String), errors : Array(String)) : String
      cleaned = spec

      # Auto-fix: remove ?- query line (we extract it separately)
      # Don't report this as a fix since buildSolverInput handles it

      # Strip comments and strings for structural analysis
      stripped = strip_prolog_noise(cleaned).strip

      return cleaned if stripped.empty?

      # Check: at least one clause ending with a period
      unless stripped.includes?('.')
        errors << "No clauses ending with a period (.) — all Prolog clauses must end with a period"
      end

      # Check: balanced parentheses
      depth = 0
      stripped.each_char do |char|
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        if depth < 0
          errors << "Unmatched closing parenthesis"
          break
        end
      end
      if depth > 0
        errors << "Unbalanced parentheses: #{depth} unclosed"
      end

      cleaned
    end

    # Convenience wrappers
    def self.lint_prolog_spec(spec : String) : LintResult
      lint_spec(spec, Solvers::SolverType::Prolog)
    end

    def self.lint_smtlib_spec(spec : String) : LintResult
      lint_spec(spec, Solvers::SolverType::Z3)
    end
  end
end
