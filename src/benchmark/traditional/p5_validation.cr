module Benchmark
  module Traditional
    record ValidationGap, field : String, description : String, example : Hash(String, Int32)?
    record ValidationGapResult, gaps : Array(ValidationGap)

    def self.solve_validation(input : NamedTuple(
                                fields: Hash(String, NamedTuple(type: String, values: Array(String)?)),
                                frontend: Hash(String, NamedTuple(min: Int32, max: Int32)),
                                backend: Hash(String, NamedTuple(min: Int32, max: Int32)),
                              )) : ValidationGapResult
      gaps = [] of ValidationGap

      input[:frontend].each do |field, frontend_rule|
        backend_rule = input[:backend][field]?
        next unless backend_rule

        f_min = frontend_rule[:min]
        f_max = frontend_rule[:max]
        b_min = backend_rule[:min]
        b_max = backend_rule[:max]

        if f_min < b_min
          gaps << ValidationGap.new(
            field: field,
            description: "Frontend allows #{field} >= #{f_min} but backend requires >= #{b_min}",
            example: {field => f_min},
          )
        end

        if f_max > b_max
          gaps << ValidationGap.new(
            field: field,
            description: "Frontend allows #{field} <= #{f_max} but backend requires <= #{b_max}",
            example: {field => b_max + 1},
          )
        end
      end

      ValidationGapResult.new(gaps: gaps)
    end
  end
end
