require "../../spec_helper"

private def swipl_available? : Bool
  # crolog requires the SWI-Prolog shared library at runtime
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe Chiasmus::Solvers::PrologSolver do
  it "resolves simple fact queries" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(
      "parent(tom, bob).\nparent(bob, ann).\nparent(bob, pat).\n",
      "parent(tom, X)."
    )

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    success = result.as(Chiasmus::Solvers::SuccessResult)
    success.answers.size.should eq(1)
    success.answers.first.bindings["X"].should eq("bob")
  end

  it "resolves recursive rules" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "ancestor(tom, Who).")
      parent(tom, bob).
      parent(bob, ann).
      ancestor(X, Y) :- parent(X, Y).
      ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    names = result.as(Chiasmus::Solvers::SuccessResult).answers.map { |answer| answer.bindings["Who"]? }.compact
    names.should contain("bob")
    names.should contain("ann")
  end

  it "returns empty answers for unsatisfiable queries" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve("parent(tom, bob).", "parent(bob, tom).")

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    result.as(Chiasmus::Solvers::SuccessResult).answers.should be_empty
  end

  it "returns an error for malformed programs" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve("parent(tom bob.", "parent(tom, X).")

    result.should be_a(Chiasmus::Solvers::ErrorResult)
    result.as(Chiasmus::Solvers::ErrorResult).error.should_not be_empty
  end

  it "returns an error for malformed queries" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve("parent(tom, bob).", "parent(tom X.")

    result.should be_a(Chiasmus::Solvers::ErrorResult)
    result.as(Chiasmus::Solvers::ErrorResult).error.should_not be_empty
  end

  it "handles arithmetic" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "factorial(5, F).")
      factorial(0, 1).
      factorial(N, F) :- N > 0, N1 is N - 1, factorial(N1, F1), F is N * F1.
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    result.as(Chiasmus::Solvers::SuccessResult).answers.first.bindings["F"].should eq("120")
  end

  it "returns derivation traces when explain is enabled" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "ancestor(tom, Who).", explain: true)
      parent(tom, bob).
      parent(bob, ann).
      ancestor(X, Y) :- parent(X, Y).
      ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    trace = result.as(Chiasmus::Solvers::SuccessResult).trace
    trace.should_not be_nil
    trace.not_nil!.join(" ").should contain("ancestor")
  end

  it "handles ground queries (no variables)" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve("parent(tom, bob).", "parent(tom, bob).")

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    result.as(Chiasmus::Solvers::SuccessResult).answers.size.should be >= 1
  end

  it "returns nil trace when explain is false (default)" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "ancestor(tom, X).")
      parent(tom, bob).
      ancestor(X, Y) :- parent(X, Y).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    result.as(Chiasmus::Solvers::SuccessResult).trace.should be_nil
  end

  it "returns trace for ground query with explain=true" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "ancestor(tom, bob).", explain: true)
      parent(tom, bob).
      ancestor(X, Y) :- parent(X, Y).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    trace = result.as(Chiasmus::Solvers::SuccessResult).trace
    trace.should_not be_nil
    trace.not_nil!.size.should be > 0
  end

  it "returns trace with multiple rule applications" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "path(a, c).", explain: true)
      edge(a, b).
      edge(b, c).
      path(X, Y) :- edge(X, Y).
      path(X, Y) :- edge(X, Z), path(Z, Y).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    trace = result.as(Chiasmus::Solvers::SuccessResult).trace
    trace.should_not be_nil
    trace.not_nil!.join(" ").should contain("path")
  end

  it "handles list operations" do
    next pending("swipl not installed") unless swipl_available?

    solver = Chiasmus::Solvers::PrologSolver.new
    result = solver.solve(<<-PROLOG, "member(X, [a, b, c]).")
      member(X, [X|_]).
      member(X, [_|T]) :- member(X, T).
    PROLOG

    result.should be_a(Chiasmus::Solvers::SuccessResult)
    values = result.as(Chiasmus::Solvers::SuccessResult).answers.map { |a| a.bindings["X"]? }.compact
    values.should contain("a")
    values.should contain("b")
    values.should contain("c")
  end
end
