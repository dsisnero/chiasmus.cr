require "../../chiasmus/solvers/z3_solver"

module Benchmark
  module Chiasmus
    record ConflictResult, has_conflict : Bool, conflicts : Array({role: String, action: String, resource: String})

    def self.solve_rbac(input : NamedTuple(
                          roles: Array(String),
                          resources: Array(String),
                          rules: Array(NamedTuple(role: String, action: String, resource: String, effect: String)),
                        )) : ConflictResult
      solver = ::Chiasmus::Solvers::Z3Solver.new

      roles_decl = input[:roles].map { |role| "(#{role})" }.join(" ")
      resources_decl = input[:resources].map { |resource| "(#{resource})" }.join(" ")
      actions = input[:rules].map { |rule| rule[:action] }.uniq!
      actions_decl = actions.map { |action| "(#{action})" }.join(" ")

      allow_rules = input[:rules]
        .select { |rule| rule[:effect] == "allow" }
        .map { |rule| "(and (= r #{rule[:role]}) (= a #{rule[:action]}) (= res #{rule[:resource]}))" }
        .join("\n    ")

      deny_rules = input[:rules]
        .select { |rule| rule[:effect] == "deny" }
        .map { |rule| "(and (= r #{rule[:role]}) (= a #{rule[:action]}) (= res #{rule[:resource]}))" }
        .join("\n    ")

      smtlib = <<-SMT
(declare-datatypes ((Role 0)) ((#{roles_decl})))
(declare-datatypes ((Action 0)) ((#{actions_decl})))
(declare-datatypes ((Resource 0)) ((#{resources_decl})))
(declare-const r Role)
(declare-const a Action)
(declare-const res Resource)
(declare-const allowed Bool)
(declare-const denied Bool)
(assert (= allowed (or #{allow_rules})))
(assert (= denied (or #{deny_rules})))
(assert allowed)
(assert denied)
SMT

      result = solver.solve(::Chiasmus::Solvers::Z3SolverInput.new(smtlib))
      case result
      when ::Chiasmus::Solvers::SatResult
        ConflictResult.new(
          has_conflict: true,
          conflicts: [{role: result.model["r"], action: result.model["a"], resource: result.model["res"]}],
        )
      else
        ConflictResult.new(has_conflict: false, conflicts: [] of {role: String, action: String, resource: String})
      end
    end
  end
end
