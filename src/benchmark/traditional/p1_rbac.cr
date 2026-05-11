module Benchmark
  module Traditional
    record ConflictResult, has_conflict : Bool, conflicts : Array({role: String, action: String, resource: String})

    def self.solve_rbac(rules : Array(NamedTuple(role: String, action: String, resource: String, effect: String))) : ConflictResult
      allows = Set(String).new
      denies = Set(String).new

      rules.each do |rule|
        key = "#{rule[:role]}|#{rule[:action]}|#{rule[:resource]}"
        if rule[:effect] == "allow"
          allows.add(key)
        elsif rule[:effect] == "deny"
          denies.add(key)
        end
      end

      conflicts = [] of {role: String, action: String, resource: String}
      allows.each do |key|
        if denies.includes?(key)
          parts = key.split("|")
          conflicts << {role: parts[0], action: parts[1], resource: parts[2]}
        end
      end

      ConflictResult.new(has_conflict: !conflicts.empty?, conflicts: conflicts)
    end
  end
end
