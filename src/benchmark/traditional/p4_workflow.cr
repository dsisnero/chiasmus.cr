module Benchmark
  module Traditional
    record WorkflowResult, unreachable_states : Array(String), dead_end_states : Array(String)

    def self.solve_workflow(input : NamedTuple(
                              initial: String,
                              states: Array(String),
                              transitions: Array(NamedTuple(from: String, to: String, action: String)),
                            )) : WorkflowResult
      adj = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      has_outgoing = Set(String).new

      input[:transitions].each do |transition|
        adj[transition[:from]] << transition[:to]
        has_outgoing.add(transition[:from])
      end

      reachable = Set(String).new
      queue = [input[:initial]]
      while queue.size > 0
        state = queue.shift
        next if reachable.includes?(state)
        reachable.add(state)
        adj[state].each { |next_state| queue << next_state }
      end

      unreachable_states = input[:states].reject { |candidate_state| reachable.includes?(candidate_state) }
      dead_end_states = input[:states].select do |candidate_state|
        reachable.includes?(candidate_state) && !has_outgoing.includes?(candidate_state) && candidate_state != input[:initial]
      end

      WorkflowResult.new(unreachable_states: unreachable_states, dead_end_states: dead_end_states)
    end
  end
end
