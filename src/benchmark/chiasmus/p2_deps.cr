require "../../chiasmus/solvers/z3_solver"

module Benchmark
  module Chiasmus
    record DependencyResult, satisfiable : Bool, assignment : Hash(String, Int32)?

    def self.solve_deps(input : NamedTuple(
                          packages: Hash(String, NamedTuple(versions: Array(Int32))),
                          requirements: Array(NamedTuple(package: String, requires: String, minVersion: Int32, condition: Int32?)),
                          incompatibilities: Array(NamedTuple(packageA: String, versionA: Int32, packageB: String, versionB: Int32)),
                        )) : DependencyResult
      solver = ::Chiasmus::Solvers::Z3Solver.new
      pkg_names = input[:packages].keys

      decls = pkg_names.map { |package| "(declare-const #{package} Int)" }.join("\n")

      ranges = pkg_names.map do |package|
        versions = input[:packages][package][:versions]
        or_clauses = versions.map { |version| "(= #{package} #{version})" }.join(" ")
        "(assert (or #{or_clauses}))"
      end.join("\n")

      deps = input[:requirements].map do |requirement|
        constraint = "(>= #{requirement[:requires]} #{requirement[:minVersion]})"
        if condition = requirement[:condition]
          "(assert (=> (>= #{requirement[:package]} #{condition}) #{constraint}))"
        else
          "(assert #{constraint})"
        end
      end.join("\n")

      incompat = input[:incompatibilities].map do |incompatibility|
        "(assert (not (and (= #{incompatibility[:packageA]} #{incompatibility[:versionA]}) (= #{incompatibility[:packageB]} #{incompatibility[:versionB]}))))"
      end.join("\n")

      smtlib = "#{decls}\n#{ranges}\n#{deps}\n#{incompat}"

      result = solver.solve(::Chiasmus::Solvers::Z3SolverInput.new(smtlib))
      case result
      when ::Chiasmus::Solvers::SatResult
        assignment = Hash(String, Int32).new
        pkg_names.each do |pkg|
          assignment[pkg] = result.model[pkg].to_i
        end
        DependencyResult.new(satisfiable: true, assignment: assignment)
      else
        DependencyResult.new(satisfiable: false, assignment: nil)
      end
    end
  end
end
