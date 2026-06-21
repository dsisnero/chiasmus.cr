require "../src/chiasmus"
require "../src/benchmark/**"

module Perf
  extend self

  def measure(label : String, runs : Int32 = 5, &) : Float64
    print "  #{label}: "
    times = [] of Float64
    runs.times do |i|
      GC.collect
      elapsed = Time.measure { yield }
      times << elapsed.total_seconds
      print "." if i > 0
    end
    avg = times[1..].sum / (runs - 1)
    printf " %.4fs avg (%d warm runs, cold: %.4fs)\n", avg, runs - 1, times[0]
    avg
  end

  def run_all
    puts "=== Baseline: Traditional (pure Crystal) ==="
    measure("RBAC conflict") { Benchmark::Traditional.solve_rbac(Benchmark::Problems::RBACRules) }

    taint_input = {
      edges:   Benchmark::Problems::DataFlowEdges,
      sources: Benchmark::Problems::DataFlowSources,
      sinks:   Benchmark::Problems::DataFlowSinks,
    }
    measure("Dataflow taint") { Benchmark::Traditional.solve_taint(taint_input) }

    if system("which z3 > /dev/null 2>&1")
      puts "\n=== Baseline: Chiasmus (Z3 solver) ==="
      z3_rbac = {
        roles:     Benchmark::Problems::RBACRoles,
        resources: Benchmark::Problems::RBACResources,
        rules:     Benchmark::Problems::RBACRules,
      }
      measure("RBAC conflict (Z3)") { Benchmark::Chiasmus.solve_rbac(z3_rbac) }
      measure("Dataflow taint (Z3)") { Benchmark::Chiasmus.solve_taint(taint_input) }
    else
      puts "\n=== Skipping Z3 (not installed) ==="
    end

    if system("which swipl > /dev/null 2>&1")
      puts "\n=== Baseline: Chiasmus (Prolog solver) ==="
      prolog_solver = ::Chiasmus::Solvers::PrologSolver.new
      measure("Small ancestor query") {
        prolog_solver.solve("parent(tom, bob).\nparent(bob, ann).\nancestor(X,Y) :- parent(X,Y).\nancestor(X,Y) :- parent(X,Z), ancestor(Z,Y).", "ancestor(tom, X).")
      }
      measure("Graph reachability") {
        prolog_solver.solve("edge(a,b).\nedge(b,c).\nedge(c,d).\nreaches(X,Y):-edge(X,Y).\nreaches(X,Y):-edge(X,Z),reaches(Z,Y).", "reaches(a, d).")
      }
    else
      puts "\n=== Skipping Prolog (swipl not installed) ==="
    end
  end
end

Perf.run_all
