require "../../chiasmus/solvers/z3_solver"

module Benchmark
  module Chiasmus
    record ValidationGap, field : String, description : String, example : Hash(String, Int32)?
    record ValidationGapResult, gaps : Array(ValidationGap)

    def self.solve_validation(input : NamedTuple(
                                fields: Hash(String, NamedTuple(type: String, values: Array(String)?)),
                                frontend: Hash(String, NamedTuple(min: Int32, max: Int32)),
                                backend: Hash(String, NamedTuple(min: Int32, max: Int32)),
                              )) : ValidationGapResult
      solver = ::Chiasmus::Solvers::Z3Solver.new
      gaps = [] of ValidationGap

      input[:frontend].each do |field, frontend_rule|
        backend_rule = input[:backend][field]?
        next unless backend_rule

        smtlib = build_gap_check(field, frontend_rule, backend_rule)
        result = solver.solve(::Chiasmus::Solvers::Z3SolverInput.new(smtlib))

        case result
        when ::Chiasmus::Solvers::SatResult
          value = result.model[field].to_i
          gaps << ValidationGap.new(
            field: field,
            description: "Frontend accepts #{field}=#{value} but backend rejects it",
            example: {field => value},
          )
        end
      end

      ValidationGapResult.new(gaps: gaps)
    end

    def self.build_gap_check(field : String, frontend : NamedTuple(min: Int32, max: Int32), backend : NamedTuple(min: Int32, max: Int32)) : String
      lines = ["(declare-const #{field} Int)"]
      lines << "(assert (>= #{field} #{frontend[:min]}))"
      lines << "(assert (<= #{field} #{frontend[:max]}))"

      backend_conditions = [] of String
      backend_conditions << "(>= #{field} #{backend[:min]})"
      backend_conditions << "(<= #{field} #{backend[:max]})"

      backend_valid = "(and #{backend_conditions.join(" ")})"
      lines << "(assert (not #{backend_valid}))"

      lines.join("\n")
    end
  end
end
