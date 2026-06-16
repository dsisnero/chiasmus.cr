require "../../spec_helper"

describe Chiasmus::Formalize do
  describe ".lint_spec" do
    describe "auto-fixes" do
      it "strips markdown fences" do
        result = Chiasmus::Formalize.lint_spec("```smt\n(declare-const x Int)\n(assert (> x 5))\n```", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
        result.fixes.should_not be_empty
        result.spec.should_not contain("```")
        result.spec.should contain("(declare-const x Int)")
      end

      it "removes check-sat from z3 specs" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int)\n(assert (> x 5))\n(check-sat)", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
        result.fixes.any? { |fix| /check-sat/i.matches?(fix) }.should be_true
        result.spec.should_not contain("check-sat")
      end

      it "removes get-model from z3 specs" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int)\n(assert (> x 5))\n(get-model)", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
        result.spec.should_not contain("get-model")
      end

      it "removes set-logic from z3 specs" do
        result = Chiasmus::Formalize.lint_spec("(set-logic QF_LIA)\n(declare-const x Int)\n(assert (> x 5))", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
        result.spec.should_not contain("set-logic")
      end
    end

    describe "error detection" do
      it "catches empty spec" do
        result = Chiasmus::Formalize.lint_spec("", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should_not be_empty
        result.errors.first.should match(/empty/i)
      end

      it "catches unfilled template slots" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int)\n(assert (> x {{SLOT:threshold}}))", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should_not be_empty
        result.errors.first.should contain("SLOT:threshold")
      end

      it "catches unbalanced z3 parentheses when unclosed" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int)\n(assert (> x 5)", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should_not be_empty
        result.errors.first.should match(/unbalanced/i)
      end

      it "catches unbalanced z3 parentheses when extra close" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int))\n(assert (> x 5))", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should_not be_empty
        result.errors.first.should match(/unmatched.*closing/i)
      end

      it "catches missing periods in prolog" do
        result = Chiasmus::Formalize.lint_spec("parent(tom, bob)\nparent(bob, ann)", Chiasmus::Solvers::SolverType::Prolog)

        result.errors.should_not be_empty
        result.errors.first.should match(/period/i)
      end

      it "catches an unterminated last clause in a multi-clause spec" do
        result = Chiasmus::Formalize.lint_spec(
          "parent(tom, bob).\nparent(bob, ann)",
          Chiasmus::Solvers::SolverType::Prolog,
        )

        result.errors.should_not be_empty
        result.errors.first.should match(/period/i)
      end

      it "catches a spec whose only period is a float decimal point" do
        result = Chiasmus::Formalize.lint_spec(
          "weight(item, 3.14)",
          Chiasmus::Solvers::SolverType::Prolog,
        )

        result.errors.should_not be_empty
        result.errors.first.should match(/period/i)
      end

      it "catches unbalanced prolog parentheses" do
        result = Chiasmus::Formalize.lint_spec("parent(tom, bob.\nparent(bob, ann).", Chiasmus::Solvers::SolverType::Prolog)

        result.errors.should_not be_empty
        result.errors.any? { |error| /parenthes/i.matches?(error) }.should be_true
      end
    end

    describe "valid specs pass clean" do
      it "accepts valid z3 with no errors or fixes" do
        result = Chiasmus::Formalize.lint_spec("(declare-const x Int)\n(assert (> x 5))", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
        result.fixes.should be_empty
      end

      it "accepts valid prolog with no errors or fixes" do
        result = Chiasmus::Formalize.lint_spec("parent(tom, bob).\nparent(bob, ann).", Chiasmus::Solvers::SolverType::Prolog)

        result.errors.should be_empty
        result.fixes.should be_empty
      end

      it "accepts z3 with comments" do
        result = Chiasmus::Formalize.lint_spec("; comment with (\n(declare-const x Int)\n(assert (= x 5))", Chiasmus::Solvers::SolverType::Z3)

        result.errors.should be_empty
      end

      it "accepts prolog with comments" do
        result = Chiasmus::Formalize.lint_spec("% comment\nparent(tom, bob).", Chiasmus::Solvers::SolverType::Prolog)

        result.errors.should be_empty
      end

      it "accepts prolog with doubled-quote escape in atom" do
        result = Chiasmus::Formalize.lint_spec(
          "says(user, 'it''s fine').",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end

      it "accepts prolog with backslash-quote escape in atom" do
        result = Chiasmus::Formalize.lint_spec(
          "says(user, 'it\\'s fine').",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end

      it "accepts prolog with percent inside a quoted atom (not a comment)" do
        result = Chiasmus::Formalize.lint_spec(
          "p('50% done').",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end

      it "accepts prolog with paren inside a quoted atom" do
        result = Chiasmus::Formalize.lint_spec(
          "p('opener: (').",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end

      it "accepts prolog with /* inside a quoted atom (not a block comment)" do
        result = Chiasmus::Formalize.lint_spec(
          "p('/* not a comment */').",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end

      it "Prolog with a float in a terminated clause passes" do
        result = Chiasmus::Formalize.lint_spec(
          "weight(item, 3.14).",
          Chiasmus::Solvers::SolverType::Prolog,
        )
        result.errors.should be_empty
      end
    end
    describe "SMT-LIB string literal validation" do
      it "handles SMT-LIB doubled-quote escape within strings" do
        result = Chiasmus::Formalize.lint_spec(
          %[(assert (= x "He said ""hello"""))],
          Chiasmus::Solvers::SolverType::Z3,
        )
        result.errors.none?(&.includes?("Unbalanced")).should be_true
        result.errors.none?(&.includes?("Unmatched")).should be_true
      end

      it "handles nested parens inside SMT-LIB strings with doubled quotes" do
        result = Chiasmus::Formalize.lint_spec(
          %[(assert (= x "a(""b"))],
          Chiasmus::Solvers::SolverType::Z3,
        )
        result.errors.none?(&.includes?("Unbalanced")).should be_true
        result.errors.none?(&.includes?("Unmatched")).should be_true
      end

      it "reports unbalanced parens outside strings correctly" do
        result = Chiasmus::Formalize.lint_spec(
          %[(assert (= x "hello")],
          Chiasmus::Solvers::SolverType::Z3,
        )
        result.errors.any?(&.includes?("Unbalanced")).should be_true
      end

      it "does not misinterpret backslash before quote as escape" do
        result = Chiasmus::Formalize.lint_spec(
          %[(assert (= msg "hello\\"extra"))],
          Chiasmus::Solvers::SolverType::Z3,
        )
        result.errors.any?(&.includes?("Unbalanced")).should be_true
      end
    end
  end
end
