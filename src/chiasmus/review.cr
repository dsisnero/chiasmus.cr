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

      selected_focus = focus || "all"
      unless VALID_FOCUS.includes?(selected_focus)
        raise ArgumentError.new("Unknown focus: #{selected_focus}. Use one of: #{VALID_FOCUS.to_a.join(", ")}")
      end

      phase_overview = make_overview_phase(files)
      phase_architecture = make_architecture_phase(files, entry_points)
      phase_security = make_security_phase(files)
      phase_resource = make_resource_safety_phase(files)
      phase_authorization = make_authorization_phase
      phase_correctness = make_correctness_phase
      phase_impact = make_impact_phase(files)

      phases = [] of ReviewPhase
      case selected_focus
      when "quick"
        phases.concat([phase_overview, phase_architecture])
      when "architecture"
        phases.concat([phase_overview, phase_architecture, phase_impact])
      when "security"
        phases.concat([phase_overview, phase_security, phase_resource, phase_authorization])
      when "correctness"
        phases.concat([phase_overview, phase_correctness, phase_impact])
      else
        phases.concat([
          phase_overview,
          phase_architecture,
          phase_security,
          phase_resource,
          phase_authorization,
          phase_correctness,
          phase_impact,
        ])
      end

      if delta_against
        phases.unshift(make_delta_phase(files, delta_against))
      end

      ReviewPlan.new(
        files: files,
        focus: selected_focus,
        summary: build_summary(selected_focus, phases.size),
        phases: phases,
        suggested_templates: pick_suggested_templates(selected_focus),
        reporting: build_reporting(delta_against),
      )
    end

    private def build_summary(focus : String, phase_count : Int32) : String
      "Code review plan (focus: #{focus}) with #{phase_count} phases. " \
      "Execute phases in order. For each action, call the named tool with the given args, " \
      "then apply the 'interpret' guidance to decide whether to flag the result as an issue. " \
      "After all phases, produce the final report per the 'reporting' section."
    end

    private def make_graph_action(
      analysis : String,
      interpret : String,
      files : Array(String),
      entry_points : Array(String)? = nil,
      against : String? = nil,
      target : String? = nil,
      from : String? = nil,
      to : String? = nil,
    ) : ReviewAction
      args = {
        "files"    => json_any(files),
        "analysis" => JSON::Any.new(analysis),
      }
      args["entry_points"] = json_any(entry_points) if entry_points
      args["against"] = JSON::Any.new(against) if against
      args["target"] = JSON::Any.new(target) if target
      args["from"] = JSON::Any.new(from) if from
      args["to"] = JSON::Any.new(to) if to
      ReviewAction.new(tool: "chiasmus_graph", args: args, interpret: interpret)
    end

    private def make_formalize_action(problem : String, interpret : String) : ReviewAction
      ReviewAction.new(
        tool: "chiasmus_formalize",
        args: {"problem" => JSON::Any.new(problem)},
        interpret: interpret,
      )
    end

    private def json_any(values : Array(String)) : JSON::Any
      JSON.parse(values.to_json)
    end

    private def make_delta_phase(files : Array(String), against : String) : ReviewPhase
      ReviewPhase.new(
        phase: "0. PR delta scope",
        goal: "Compare the current code against a previously saved snapshot (usually the base branch) " \
              "to identify which symbols this PR adds, removes, or rewires. The delta drives the later " \
              "phases — expensive analyses focus on changed symbols instead of the entire codebase. " \
              "Cross-module rewiring flagged here is frequently the root cause of regressions.",
        actions: [
          make_graph_action(
            "diff",
            "Returns { addedNodes, removedNodes, addedEdges, removedEdges, summary }. Requires a snapshot " \
            "named '#{against}' to exist (created earlier via chiasmus_graph save_snapshot='#{against}' on the base branch). " \
            "If the result is a snapshot-not-found error, ask for a baseline extraction first, then skip this phase. " \
            "Treat every name in addedNodes as a primary review target for the later phases. Each addedEdge crossing module " \
            "boundaries is a candidate architectural regression: escalate to MEDIUM by default, HIGH if the endpoint is a " \
            "public API. Each removedNode should be impact-checked against the current graph: if callers outside the PR still " \
            "reference it, flag CRITICAL (broken symbol).",
            files,
            against: against
          ),
          make_graph_action(
            "impact",
            "Run this once per entry in removedNodes, substituting the name for <REMOVED_NODE>. Non-empty result means the PR " \
            "deletes a symbol that is still referenced somewhere — either the callers were supposed to be updated too (PR is " \
            "incomplete) or the analysis is missing the migration file. Severity: CRITICAL.",
            files,
            target: "<REMOVED_NODE>"
          ),
        ]
      )
    end

    private def make_overview_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "1. Structural overview",
        goal: "Get a baseline for the scope and shape of the code before deep analysis — function count, " \
              "call edge count, import graph size. Helps calibrate which later phases are worth running.",
        actions: [
          make_graph_action(
            "summary",
            "Record files, functions, callEdges, imports, exports. A high callEdges:functions ratio (>5:1) suggests " \
            "tight coupling — expect more layer violations and cycles below. Very low edges may mean tree-sitter " \
            "missed calls (dynamic dispatch, reflection) — adjust expectations.",
            files
          ),
        ]
      )
    end

    private def make_architecture_phase(files : Array(String), entry_points : Array(String)?) : ReviewPhase
      ReviewPhase.new(
        phase: "2. Architecture health",
        goal: "Surface structural problems: unreachable functions, circular dependencies, and calls that skip " \
              "abstraction layers. These are objective defects — no judgment calls required.",
        actions: [
          make_graph_action(
            "dead-code",
            "Each returned name is a function unreachable from any entry point. Before flagging, verify it isn't an " \
            "exported public API, a test fixture, or a framework hook. Remaining names are candidate deletions — severity: LOW to MEDIUM.",
            files,
            entry_points
          ),
          make_graph_action(
            "cycles",
            "Each entry is a function that transitively calls itself. Mutual recursion between modules signals a tangled " \
            "dependency that blocks incremental refactoring. Severity: MEDIUM. If the cycle spans a module boundary, escalate to HIGH.",
            files
          ),
          make_graph_action(
            "layer-violation",
            "Each entry is a call that skips layers (for example, handler → db without going through services). These violate " \
            "the intended architecture. Severity: MEDIUM. Only relevant if the codebase uses conventional layering.",
            files
          ),
        ]
      )
    end

    private def make_security_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "3. Security — data flow and taint",
        goal: "Trace untrusted input from entry points to sensitive sinks (SQL, shell, HTTP response, file I/O). " \
              "Any unsanitized path is a candidate injection vulnerability.",
        actions: [
          make_graph_action(
            "facts",
            "This returns raw Prolog facts for the call graph. Keep the output — you'll reuse the calls/2 facts as the " \
            "'flow_facts' slot when filling the taint-propagation template below. Alternatively use reachability queries " \
            "directly for simple source→sink checks.",
            files
          ),
          make_formalize_action(
            "Trace tainted user input through data flow to sensitive sinks like SQL or HTTP response",
            "Expected template: taint-propagation. Fill slots: flow_facts from the facts dump above, taint_sources with " \
            "request-param functions, sanitizers with escape/validate/parameterize functions, sinks with execute_sql/exec/eval/writeResponse. " \
            "Then call chiasmus_verify with solver='prolog' and query='violation(X).' — each X is a tainted sink reachable without sanitization. " \
            "Severity: HIGH to CRITICAL."
          ),
          make_graph_action(
            "reachability",
            "Optional lightweight check: if you already know a specific source and sink, call this for each pair. Replace " \
            "<USER_INPUT_FN> and <SINK_FN> with actual function names from the summary. Faster than taint-propagation but gives no sanitizer awareness.",
            files,
            from: "<USER_INPUT_FN>",
            to: "<SINK_FN>"
          ),
        ]
      )
    end

    private def make_resource_safety_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "4. Resource safety — paired operations",
        goal: "Detect leaked resources: functions that acquire without releasing (lock/unlock, open/close, begin/commit, init/cleanup). " \
              "These cause deadlocks, file handle exhaustion, and transaction leaks.",
        actions: [
          make_graph_action(
            "facts",
            "Reuse the facts dump from phase 3 if already obtained. You need the calls/2 facts showing which functions call which operations.",
            files
          ),
          make_formalize_action(
            "Check that every lock/open/begin call has a matching unlock/close/commit in the same function",
            "Expected template: association-rule-check. Fill required_pairs with the paired operations relevant to this codebase — " \
            "for example mutex.lock → mutex.unlock, fs.open → fs.close, db.begin → db.commit, ctx.acquire → ctx.release. " \
            "Then chiasmus_verify with query='missing_pair(Func, Expected).' — each answer is a function missing the pair. " \
            "Severity: HIGH for locks/transactions, MEDIUM for file handles."
          ),
        ]
      )
    end

    private def make_authorization_phase : ReviewPhase
      ReviewPhase.new(
        phase: "5. Authorization — policy contradictions",
        goal: "If the codebase has RBAC, ACL, or any allow/deny rule set, verify no (principal, action, resource) triple can be both " \
              "allowed and denied. Only run this phase if the codebase actually contains authorization logic.",
        actions: [
          make_formalize_action(
            "Check if access control allow/deny rules can ever produce contradictory decisions for the same request",
            "Expected template: policy-contradiction. Extract the allow and deny rules from the code — usually a switch, a rule table, " \
            "or middleware chain. Fill type_declarations with the enum of roles/actions/resources you see. Then chiasmus_verify — SAT " \
            "means a contradictory request exists (the model shows the exact conflict). Severity: HIGH."
          ),
          ReviewAction.new(
            tool: "chiasmus_skills",
            args: {"query" => JSON::Any.new("check if a principal can escalate to reach a forbidden resource")},
            interpret: "Follow-up: if policy-contradiction returns SAT or the codebase uses role inheritance, also apply policy-reachability " \
                       "and permission-derivation templates. The chiasmus_skills search returns candidates ranked by BM25."
          ),
        ]
      )
    end

    private def make_correctness_phase : ReviewPhase
      ReviewPhase.new(
        phase: "6. Correctness — invariants, boundaries, state machines",
        goal: "Hunt for bugs in specific hotspot functions identified in earlier phases: off-by-one errors, overflow, state machine " \
              "deadlocks, broken postconditions. This phase is function-targeted — run it once per suspect function, not once per file.",
        actions: [
          make_formalize_action(
            "Verify a function's postcondition holds for all inputs satisfying its precondition",
            "Expected template: invariant-check. For each function with non-trivial numeric logic (pricing, balance, retry counts, pagination), " \
            "extract input_declarations, function_body as SMT assertions, precondition from input validation, postcondition from the documented " \
            "or expected result property. SAT = counterexample input; UNSAT = invariant holds."
          ),
          make_formalize_action(
            "Check numeric boundary conditions for off-by-one errors and overflow on array indices and loop counters",
            "Expected template: boundary-condition. Apply to loops, array access, and arithmetic that mixes signed/unsigned or bounded types. " \
            "SAT means the bug is reachable under the given domain_constraints — the model shows the triggering input."
          ),
          make_formalize_action(
            "Detect unreachable states and invalid transitions in a state machine",
            "Expected template: state-machine-deadlock. Only apply if the code has an explicit state field and transition logic. Skip otherwise."
          ),
        ]
      )
    end

    private def make_impact_phase(files : Array(String)) : ReviewPhase
      ReviewPhase.new(
        phase: "7. Impact analysis on flagged functions",
        goal: "For every function flagged as buggy, insecure, or structurally problematic in earlier phases, compute its blast radius. " \
              "A bug in a widely-called utility is much more severe than the same bug in an isolated leaf function.",
        actions: [
          make_graph_action(
            "impact",
            "Call this once per flagged function, substituting the name for <FLAGGED_FUNCTION>. If there are many callers, escalate severity. " \
            "If a caller is an entry point (HTTP handler, CLI command, scheduled job), escalate further.",
            files,
            target: "<FLAGGED_FUNCTION>"
          ),
        ]
      )
    end

    private def pick_suggested_templates(focus : String) : Array(SuggestedTemplate)
      templates = {
        "taint-propagation" => SuggestedTemplate.new(
          template: "taint-propagation",
          when: "User input must not reach SQL, shell, eval, file paths, or HTTP response without sanitization",
          workflow: "chiasmus_graph analysis='facts' → chiasmus_formalize problem='taint flow' → fill flow_facts + sources + sinks + sanitizers → chiasmus_verify query='violation(X).'",
        ),
        "association-rule-check" => SuggestedTemplate.new(
          template: "association-rule-check",
          when: "Every acquire must have a matching release (lock/unlock, open/close, begin/commit)",
          workflow: "chiasmus_graph analysis='facts' → chiasmus_formalize problem='paired operations' → fill required_pairs → chiasmus_verify query='missing_pair(F, E).'",
        ),
        "collective-classification" => SuggestedTemplate.new(
          template: "collective-classification",
          when: "Propagate a property (sensitive, can_fail, deprecated) from seed functions through the call graph",
          workflow: "chiasmus_graph analysis='facts' → chiasmus_formalize problem='label propagation' → seed labels → chiasmus_verify query='<label>_prop(X).'",
        ),
        "policy-contradiction" => SuggestedTemplate.new(
          template: "policy-contradiction",
          when: "Codebase has access-control allow/deny rules that could conflict",
          workflow: "chiasmus_formalize problem='policy conflict' → extract rules from code → chiasmus_verify (SAT = conflict)",
        ),
        "policy-reachability" => SuggestedTemplate.new(
          template: "policy-reachability",
          when: "Check if a specific principal can reach a sensitive resource via any rule chain",
          workflow: "chiasmus_formalize problem='can principal reach resource' → chiasmus_verify",
        ),
        "permission-derivation" => SuggestedTemplate.new(
          template: "permission-derivation",
          when: "Codebase uses role hierarchy / inheritance — compute effective permissions",
          workflow: "chiasmus_formalize problem='derive inherited permissions' → chiasmus_verify",
        ),
        "invariant-check" => SuggestedTemplate.new(
          template: "invariant-check",
          when: "Specific function has a documented or expected postcondition to verify",
          workflow: "chiasmus_formalize problem='verify postcondition' → fill function_body + pre + post → chiasmus_verify (SAT = counterexample)",
        ),
        "boundary-condition" => SuggestedTemplate.new(
          template: "boundary-condition",
          when: "Loop indices, array access, or numeric arithmetic may over/underflow",
          workflow: "chiasmus_formalize problem='boundary check' → fill computation + domain + violation → chiasmus_verify",
        ),
        "state-machine-deadlock" => SuggestedTemplate.new(
          template: "state-machine-deadlock",
          when: "Code has explicit state field + transition rules",
          workflow: "chiasmus_formalize problem='state reachability' → chiasmus_verify",
        ),
        "graph-reachability" => SuggestedTemplate.new(
          template: "graph-reachability",
          when: "Arbitrary graph-reachability question that doesn't fit the built-in chiasmus_graph analyses",
          workflow: "chiasmus_formalize problem='reachability' → fill edges → chiasmus_verify",
        ),
      }

      case focus
      when "security"
        [
          templates["taint-propagation"],
          templates["association-rule-check"],
          templates["policy-contradiction"],
          templates["policy-reachability"],
          templates["collective-classification"],
        ]
      when "architecture"
        [templates["graph-reachability"], templates["collective-classification"]]
      when "correctness"
        [
          templates["invariant-check"],
          templates["boundary-condition"],
          templates["state-machine-deadlock"],
        ]
      when "quick"
        [templates["graph-reachability"]]
      else
        templates.values
      end
    end

    private def build_reporting(delta_against : String?) : ReviewReporting
      delta_line = if delta_against
                     "\n  0. **Changes in this PR**: lead with the graph_diff summary from phase 0 — added symbols, removed symbols, rewired edges. " \
                     "Reviewers should open with what changed before hearing about every defect.\n"
                   else
                     ""
                   end

      ReviewReporting.new(
        format: "Numbered issue list with severity",
        severity_levels: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO"],
        instructions: "After executing all phases, produce a final report. Structure:\n" \
                      "#{delta_line}" \
                      "  1. **Summary**: one-paragraph overview of the codebase and the review scope.\n" \
                      "  2. **Issues**: numbered list, each with: (a) severity label, (b) file:line reference, (c) which chiasmus tool/template " \
                      "surfaced it, (d) concrete evidence (model, violating input, call chain), (e) suggested fix.\n" \
                      "  3. **Clean areas**: briefly note phases that found nothing — explicit negative results are valuable.\n" \
                      "Severity guide: CRITICAL = exploitable security bug or data loss path; HIGH = correctness bug affecting production paths or " \
                      "architecture violation spanning modules; MEDIUM = localized bug or layer violation inside a module; LOW = dead code or cosmetic " \
                      "structural issue; INFO = observations that aren't defects.",
      )
    end
  end
end
