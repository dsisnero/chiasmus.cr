# Ported from vendor/chiasmus/src/review.ts
#
# Code review plan builder. Returns a structured, phased recipe that
# tells the calling LLM exactly which chiasmus tools and templates
# to invoke, in what order, and what to look for.

module Chiasmus
  module Review
    extend self

    record ReviewAction,
      tool : String,
      args : Hash(String, JSON::Any),
      interpret : String

    record ReviewPhase,
      phase : String,
      goal : String,
      actions : Array(ReviewAction)

    record SuggestedTemplate,
      template : String,
      when : String,
      workflow : String

    record ReviewReporting,
      format : String,
      severity_levels : Array(String),
      instructions : String

    record ReviewPlan,
      files : Array(String),
      focus : String,
      summary : String,
      phases : Array(ReviewPhase),
      suggested_templates : Array(SuggestedTemplate),
      reporting : ReviewReporting

    VALID_FOCUS = Set{"all", "security", "architecture", "correctness", "quick"}

    def build_plan(
      files : Array(String),
      focus : String? = nil,
      entry_points : Array(String)? = nil,
      delta_against : String? = nil,
    ) : ReviewPlan
      raise ArgumentError.new("'files' must be a non-empty array") if files.empty?
      f = focus || "all"
      raise ArgumentError.new("Unknown focus: #{f}. Use one of: #{VALID_FOCUS.to_a.join(", ")}") unless VALID_FOCUS.includes?(f)

      phase_overview = make_overview_phase(files)
      phase_architecture = make_architecture_phase(files, entry_points)
      phase_security = make_security_phase(files)
      phase_resource = make_resource_safety_phase(files)
      phase_authorization = make_authorization_phase
      phase_correctness = make_correctness_phase
      phase_impact = make_impact_phase(files)

      phases = [] of ReviewPhase
      case f
      when "quick"
        phases.concat([phase_overview, phase_architecture])
      when "architecture"
        phases.concat([phase_overview, phase_architecture, phase_impact])
      when "security"
        phases.concat([phase_overview, phase_security, phase_resource, phase_authorization])
      when "correctness"
        phases.concat([phase_overview, phase_correctness, phase_impact])
      else # "all"
        phases.concat([
          phase_overview, phase_architecture, phase_security,
          phase_resource, phase_authorization, phase_correctness, phase_impact,
        ])
      end

      if delta_against
        phases.unshift(make_delta_phase(files, delta_against))
      end

      ReviewPlan.new(
        files: files,
        focus: f,
        summary: build_summary(f, phases.size),
        phases: phases,
        suggested_templates: pick_suggested_templates(f),
        reporting: build_reporting(delta_against),
      )
    end

    private def build_summary(focus : String, phase_count : Int32) : String
      "Code review plan (focus: #{focus}) with #{phase_count} phases. " \
      "Execute phases in order. For each action, call the named tool with the given args, " \
      "then apply the 'interpret' guidance to decide whether to flag the result as an issue. " \
      "After all phases, produce the final report per the 'reporting' section."
    end

    private def a(args : NamedTuple) : JSON::Any
      hash = Hash(String, JSON::Any).new
      args.to_h.each { |k, v| hash[k.to_s] = json_any(v) }
      JSON.parse(hash.to_json)
    end

    private def json_any(v : Array(String)) : JSON::Any
      JSON.parse(v.to_json)
    end

    private def json_any(v : String) : JSON::Any
      JSON::Any.new(v)
    end

    private def json_any(v : Bool) : JSON::Any
      JSON::Any.new(v)
    end

    private def make_graph_action(analysis : String, interpret : String, files : Array(String), entry_points : Array(String)? = nil) : ReviewAction
      args = {} of String => JSON::Any
      args["files"] = json_any(files)
      args["analysis"] = JSON::Any.new(analysis)
      args["entry_points"] = json_any(entry_points) if entry_points
      ReviewAction.new(tool: "chiasmus_graph", args: args, interpret: interpret)
    end

    private def make_formalize_action(template : String, interpret : String) : ReviewAction
      ReviewAction.new(
        tool: "chiasmus_formalize",
        args: {"template" => JSON::Any.new(template)},
        interpret: interpret,
      )
    end

    private def make_delta_phase(files : Array(String), against : String) : ReviewPhase
      ReviewPhase.new(
        phase: "0. PR delta scope",
        goal: "Compare the current code against a previously saved snapshot to identify changed symbols. " \
              "The delta drives later phases — expensive analyses focus on changed symbols.",
        actions: [
          make_graph_action("diff", "Returns addedNodes, removedNodes, addedEdges, removedEdges. Every addedNode is a primary review target. AddedEdge crossing module boundaries → MEDIUM, HIGH if public API. Each removedNode → impact-check (CRITICAL if still referenced).", files),
        ],
      )
    end

    private def make_overview_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "1. Structural overview",
        goal: "Understand the codebase shape: file tree, exports, key symbols.",
        actions: [
          make_graph_action("summary", "Review file counts, node counts, edge counts for anomalies.", files),
          make_graph_action("entry-points", "Identifies public-facing entry points. These drive dead-code analysis.", files),
        ],
      )
    end

    private def make_architecture_phase(files : Array(String), entry_points : Array(String)?) : ReviewPhase
      ReviewPhase.new(
        phase: "2. Architecture & dependency hygiene",
        goal: "Detect dead code, circular dependencies, and layer-skipping calls.",
        actions: [
          make_graph_action("dead-code", "Symbols unreachable from entry points. Flag LOW removal candidates.", files, entry_points),
          make_graph_action("cycles", "Circular dependencies require refactoring. Flag MEDIUM.", files),
          make_graph_action("layer-violation", "Handler→DB skipping Service layer violates architecture. Flag HIGH.", files),
          make_graph_action("hubs", "Over-connected nodes centralize risk. Flag review candidates.", files),
          make_graph_action("bridges", "High-betweenness nodes whose removal fragments the graph.", files),
        ],
      )
    end

    private def make_security_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "3. Security: taint & data flow",
        goal: "Trace untrusted data from sources to sinks. Detect missing sanitizers.",
        actions: [
          make_graph_action("callers", "Trace callers of each function — build data-flow chains manually.", files),
          make_formalize_action("taint-propagation", "Run taint-propagation on each source→sink pair found. Flag unsanitized paths as CRITICAL."),
        ],
      )
    end

    private def make_resource_safety_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "4. Resource safety",
        goal: "Detect missing close/dispose, double-free, and resource leaks.",
        actions: [
          make_graph_action("callees", "For each resource-acquiring function, trace callees for missing release.", files),
          make_formalize_action("boundary-condition", "Check resource lifecycle boundary conditions."),
        ],
      )
    end

    private def make_authorization_phase : ReviewPhase
      ReviewPhase.new(
        phase: "5. Authorization & access control",
        goal: "Verify that sensitive operations are gated by authorization checks.",
        actions: [
          ReviewAction.new(
            tool: "chiasmus_formalize",
            args: {"template" => JSON::Any.new("policy-contradiction-check")},
            interpret: "Check for contradictions between stated access policies and actual code paths.",
          ),
          ReviewAction.new(
            tool: "chiasmus_formalize",
            args: {"template" => JSON::Any.new("association-rule")},
            interpret: "Verify that authorization check→sensitive-operation pairs are consistent.",
          ),
        ],
      )
    end

    private def make_correctness_phase : ReviewPhase
      ReviewPhase.new(
        phase: "6. Correctness & invariants",
        goal: "Verify core invariants, state machine properties, and boundary conditions.",
        actions: [
          ReviewAction.new(
            tool: "chiasmus_formalize",
            args: {"template" => JSON::Any.new("invariant-check")},
            interpret: "Express critical invariants (x > 0, balance matches, etc.) and verify they hold.",
          ),
          ReviewAction.new(
            tool: "chiasmus_formalize",
            args: {"template" => JSON::Any.new("state-machine-deadlock")},
            interpret: "Model state transitions and check for deadlock states.",
          ),
          ReviewAction.new(
            tool: "chiasmus_formalize",
            args: {"template" => JSON::Any.new("boundary-condition")},
            interpret: "Test edge cases: empty inputs, max values, concurrent access.",
          ),
        ],
      )
    end

    private def make_impact_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "7. Impact analysis",
        goal: "Assess downstream impact of changes to key symbols.",
        actions: [
          make_graph_action("impact", "For each key symbol, identify all transitive dependents.", files),
          make_graph_action("surprises", "Cross-community edges and peripheral-to-hub connections worth reviewing.", files),
        ],
      )
    end

    private def pick_suggested_templates(focus : String) : Array(SuggestedTemplate)
      all_templates = [
        SuggestedTemplate.new(
          template: "taint-propagation",
          when: "Any function that receives user input or reads external data",
          workflow: "chiasmus_formalize → identify sources/sinks → chiasmus_verify",
        ),
        SuggestedTemplate.new(
          template: "invariant-check",
          when: "Mutable state that must satisfy a property (balance ≥ 0, array sorted, etc.)",
          workflow: "chiasmus_formalize → express invariant → chiasmus_verify",
        ),
        SuggestedTemplate.new(
          template: "boundary-condition",
          when: "Functions with numeric inputs, array sizes, or iteration bounds",
          workflow: "chiasmus_formalize → test edge cases → chiasmus_verify",
        ),
        SuggestedTemplate.new(
          template: "state-machine-deadlock",
          when: "Code with explicit state transitions (order processing, auth flows)",
          workflow: "chiasmus_formalize → model states → chiasmus_verify for deadlock",
        ),
        SuggestedTemplate.new(
          template: "policy-contradiction-check",
          when: "Access control or authorization logic",
          workflow: "chiasmus_formalize → state policy → chiasmus_verify for contradictions",
        ),
        SuggestedTemplate.new(
          template: "association-rule",
          when: "Related operations that should always co-occur (lock/unlock, open/close)",
          workflow: "chiasmus_formalize → express pairs → chiasmus_verify for missing pairs",
        ),
      ]

      case focus
      when "quick"
        all_templates.first(2)
      when "security"
        all_templates.select { |t| t.template.in?("taint-propagation", "policy-contradiction-check", "association-rule") }
      when "architecture"
        all_templates.first(2)
      when "correctness"
        all_templates.select { |t| t.template.in?("invariant-check", "boundary-condition", "state-machine-deadlock") }
      else
        all_templates
      end
    end

    private def build_reporting(delta_against : String?) : ReviewReporting
      ReviewReporting.new(
        format: "For each issue found, report: severity level (CRITICAL/HIGH/MEDIUM/LOW), " \
                "the tool that detected it, the affected symbol/file, a one-line description, " \
                "and a proposed fix. Group by phase, then severity.",
        severity_levels: ["CRITICAL", "HIGH", "MEDIUM", "LOW"],
        instructions: delta_against ? "PR review mode: focus on issues introduced by this PR's delta. " \
                                      "Pre-existing issues outside the delta should be noted as LOW-priority tech debt." : "Full codebase review: report all issues found.",
      )
    end
  end
end
