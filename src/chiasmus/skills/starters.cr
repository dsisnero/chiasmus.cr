module Chiasmus
  module Skills
    STARTER_TEMPLATES = [
      SkillTemplate.new(
        name: "policy-contradiction",
        domain: "authorization",
        solver: Solvers::SolverType::Z3,
        signature: "Check if access control rules can ever produce contradictory allow/deny decisions for the same request",
        skeleton: <<-TEXT,
        ; Principals, resources, and actions as enumerated types
        {{SLOT:type_declarations}}

        (declare-const r {{SLOT:principal_type}})
        (declare-const a {{SLOT:action_type}})
        (declare-const res {{SLOT:resource_type}})
        (declare-const allowed Bool)
        (declare-const denied Bool)

        ; allowed is true IFF the (r, a, res) triple matches ANY allow rule
        (assert (= allowed (or {{SLOT:allow_rules}})))

        ; denied is true IFF the (r, a, res) triple matches ANY deny rule
        (assert (= denied (or {{SLOT:deny_rules}})))

        ; Check: can both be true simultaneously?
        (assert allowed)
        (assert denied)
        TEXT
        slots: [
          SlotDef.new(name: "type_declarations", description: "SMT-LIB declare-datatypes for principals, actions, resources", format: "(declare-datatypes ((Role 0)) (((admin) (editor) (viewer))))\n(declare-datatypes ((Action 0)) (((read) (write) (delete))))\n(declare-datatypes ((Resource 0)) (((docs) (settings))))"),
          SlotDef.new(name: "principal_type", description: "Type name for principals", format: "Role"),
          SlotDef.new(name: "action_type", description: "Type name for actions", format: "Action"),
          SlotDef.new(name: "resource_type", description: "Type name for resources", format: "Resource"),
          SlotDef.new(name: "allow_rules", description: "OR of all allow conditions - each is (and (= r X) (= a Y) (= res Z))", format: "(and (= r admin) (= a read) (= res docs))\n  (and (= r editor) (= a write) (= res docs))"),
          SlotDef.new(name: "deny_rules", description: "OR of all deny conditions - each is (and (= r X) (= a Y) (= res Z))", format: "(and (= r editor) (= a delete) (= res docs))"),
        ],
        normalizations: [
          Normalization.new(source: "AWS IAM JSON", transform: "Map each Statement's Effect/Principal/Action/Resource to an (and ...) clause"),
          Normalization.new(source: "Kubernetes RBAC", transform: "Expand rules[].{verbs, resources} into (and (= a verb) (= res resource)) clauses"),
          Normalization.new(source: "natural language", transform: "Extract entities, classify as principal/action/resource, build (and ...) clauses"),
        ],
        tips: [
          "Use (= flag (or ...)) NOT (=> ... flag) - implication makes the query trivially SAT",
          "No define-fun with args - prefer declare-const plus asserts",
          "Model returns r, a, res as the exact conflicting request",
        ],
        example: <<-TEXT
        (declare-datatypes ((Role 0)) (((admin) (editor))))
        (declare-datatypes ((Action 0)) (((read) (write))))
        (declare-datatypes ((Resource 0)) (((docs) (billing))))

        (declare-const r Role)
        (declare-const a Action)
        (declare-const res Resource)
        (declare-const allowed Bool)
        (declare-const denied Bool)

        (assert (= allowed (or
          (and (= r admin) (= a read) (= res billing))
          (and (= r editor) (= a write) (= res docs))
        )))

        (assert (= denied (or
          (and (= r editor) (= a write) (= res docs))
        )))

        (assert allowed)
        (assert denied)
        TEXT
      ),
      SkillTemplate.new(
        name: "policy-reachability",
        domain: "authorization",
        solver: Solvers::SolverType::Z3,
        signature: "Check if a specific principal can ever access a specific resource through any combination of roles or rules",
        skeleton: <<-TEXT,
        {{SLOT:type_declarations}}

        (declare-const principal {{SLOT:principal_type}})
        (declare-const resource {{SLOT:resource_type}})
        (declare-const action {{SLOT:action_type}})
        (declare-const can_access Bool)

        ; Define can_access as true IFF role rules grant it
        (assert (= can_access (or {{SLOT:access_rules}})))

        ; Target: can this specific principal access this specific resource?
        (assert (= principal {{SLOT:target_principal}}))
        (assert (= resource {{SLOT:target_resource}}))
        (assert can_access)
        TEXT
        slots: [
          SlotDef.new(name: "type_declarations", description: "SMT-LIB declare-datatypes", format: "(declare-datatypes ...)"),
          SlotDef.new(name: "principal_type", description: "Type name for principals", format: "Principal"),
          SlotDef.new(name: "resource_type", description: "Type name for resources", format: "Resource"),
          SlotDef.new(name: "action_type", description: "Type name for actions", format: "Action"),
          SlotDef.new(name: "access_rules", description: "OR of conditions that grant access", format: "(and (= principal alice) (= action read) (= resource docs))"),
          SlotDef.new(name: "target_principal", description: "The principal to check", format: "alice"),
          SlotDef.new(name: "target_resource", description: "The resource to check", format: "secret_doc"),
        ],
        normalizations: [
          Normalization.new(source: "Django permissions", transform: "Extract user/group assignments and permission checks into access rule clauses"),
          Normalization.new(source: "natural language", transform: "Identify the target principal and resource, extract role hierarchy"),
        ],
        tips: [
          "Use (=) not (=>) for can_access",
          "SAT means access is possible; UNSAT means it is unreachable",
        ]
      ),
      SkillTemplate.new(
        name: "config-equivalence",
        domain: "configuration",
        solver: Solvers::SolverType::Z3,
        signature: "Check if two configurations are functionally equivalent or find an input where they differ",
        skeleton: <<-TEXT,
        ; Input variables representing all possible inputs
        {{SLOT:input_declarations}}

        ; Config A output
        (declare-const result_a Bool)
        (assert (= result_a {{SLOT:config_a_expr}}))

        ; Config B output
        (declare-const result_b Bool)
        (assert (= result_b {{SLOT:config_b_expr}}))

        ; Check: is there any input where the two configs produce different outputs?
        (assert (not (= result_a result_b)))
        TEXT
        slots: [
          SlotDef.new(name: "input_declarations", description: "Declare input variables covering the input space", format: "(declare-const port Int) (declare-const src_ip Int)"),
          SlotDef.new(name: "config_a_expr", description: "Boolean expression for config A's behavior", format: "(and (>= port 80) (<= port 443))"),
          SlotDef.new(name: "config_b_expr", description: "Boolean expression for config B's behavior", format: "(and (>= port 80) (<= port 8080))"),
        ],
        normalizations: [
          Normalization.new(source: "firewall rules", transform: "Encode each rule set as boolean expressions over port, protocol, and address variables"),
          Normalization.new(source: "Kubernetes NetworkPolicy", transform: "Map ingress and egress rules to boolean expressions over pod labels and ports"),
        ],
        tips: [
          "Use (=) to define result vars",
          "SAT means configs differ; UNSAT means they are equivalent",
        ],
        example: <<-TEXT
        (declare-const port Int)

        (declare-const result_a Bool)
        (assert (= result_a (and (>= port 80) (<= port 443))))

        (declare-const result_b Bool)
        (assert (= result_b (and (>= port 80) (<= port 8080))))

        (assert (not (= result_a result_b)))
        TEXT
      ),
      SkillTemplate.new(
        name: "constraint-satisfaction",
        domain: "dependency",
        solver: Solvers::SolverType::Z3,
        signature: "Find a valid assignment satisfying version constraints, dependency requirements, and compatibility rules",
        skeleton: <<-TEXT,
        ; Version variables for each package
        {{SLOT:version_declarations}}

        ; Version range constraints (available versions)
        {{SLOT:range_constraints}}

        ; Dependency requirements (A requires B >= version)
        {{SLOT:dependency_rules}}

        ; Incompatibility constraints
        {{SLOT:incompatibility_rules}}
        TEXT
        slots: [
          SlotDef.new(name: "version_declarations", description: "Declare an Int variable for each package version", format: "(declare-const pkg_a Int) (declare-const pkg_b Int)"),
          SlotDef.new(name: "range_constraints", description: "Constrain each package to its available versions using (or (= pkg v1) (= pkg v2) ...)", format: "(assert (or (= pkg_a 1) (= pkg_a 2) (= pkg_a 3)))"),
          SlotDef.new(name: "dependency_rules", description: "Conditional version requirements using implication", format: "(assert (=> (>= pkg_a 2) (>= pkg_b 3)))"),
          SlotDef.new(name: "incompatibility_rules", description: "Pairs of versions that cannot coexist", format: "(assert (not (and (= pkg_a 2) (= pkg_b 1))))"),
        ],
        normalizations: [
          Normalization.new(source: "package.json", transform: "Parse semver ranges into (or (= pkg v) ...) constraints, and peer dependencies into implication rules"),
          Normalization.new(source: "requirements.txt", transform: "Parse version specifiers into SMT constraints"),
        ],
        tips: [
          "Discrete versions use explicit equality disjunctions, not numeric intervals",
          "SAT means a valid assignment exists; UNSAT means no solution exists",
        ],
        example: <<-TEXT
        (declare-const app Int)
        (declare-const lib Int)
        (assert (or (= app 1) (= app 2) (= app 3)))
        (assert (or (= lib 1) (= lib 2)))
        (assert (=> (>= app 2) (>= lib 2)))
        (assert (not (and (= app 3) (= lib 1))))
        TEXT
      ),
      SkillTemplate.new(
        name: "schema-consistency",
        domain: "validation",
        solver: Solvers::SolverType::Z3,
        signature: "Check if data validation rules are contradictory, redundant, or have gaps - find inputs that pass some rules but fail others",
        skeleton: <<-TEXT,
        ; Input field variables
        {{SLOT:field_declarations}}

        ; Value passes rule set A
        (declare-const passes_a Bool)
        (assert (= passes_a (and {{SLOT:rule_set_a_conditions}})))

        ; Value passes rule set B
        (declare-const passes_b Bool)
        (assert (= passes_b (and {{SLOT:rule_set_b_conditions}})))

        ; Check: is there an input that passes A but fails B?
        (assert passes_a)
        (assert (not passes_b))
        TEXT
        slots: [
          SlotDef.new(name: "field_declarations", description: "Declare variables for each input field", format: "(declare-const age Int) (declare-const name_len Int)"),
          SlotDef.new(name: "rule_set_a_conditions", description: "Conjunction of conditions for rule set A, such as frontend validation", format: "(>= age 13) (<= age 120) (>= name_len 3)"),
          SlotDef.new(name: "rule_set_b_conditions", description: "Conjunction of conditions for rule set B, such as backend validation", format: "(>= age 18) (<= age 150) (>= name_len 3)"),
        ],
        normalizations: [
          Normalization.new(source: "JSON Schema", transform: "Map minimum, maximum, pattern, and required constraints into boolean conditions"),
          Normalization.new(source: "Zod schema", transform: "Extract chained validators into conditions"),
        ],
        tips: [
          "Use (=) to define passes_a and passes_b",
          "SAT means a validation gap exists; UNSAT means no such gap exists",
          "Swap A and B to test the opposite direction",
        ],
        example: <<-TEXT
        (declare-const age Int)

        (declare-const passes_frontend Bool)
        (assert (= passes_frontend (and (>= age 13) (<= age 120))))

        (declare-const passes_backend Bool)
        (assert (= passes_backend (and (>= age 18) (<= age 150))))

        (assert passes_frontend)
        (assert (not passes_backend))
        TEXT
      ),
      SkillTemplate.new(
        name: "rule-inference",
        domain: "rules",
        solver: Solvers::SolverType::Prolog,
        signature: "Given a set of facts and rules, derive what conclusions follow - determine eligibility, compliance, or derived properties",
        skeleton: <<-TEXT,
        % Facts about entities
        {{SLOT:facts}}

        % Rules that derive new conclusions
        {{SLOT:rules}}
        TEXT
        slots: [
          SlotDef.new(name: "facts", description: "Ground facts about the domain", format: "role(alice, admin). department(alice, engineering)."),
          SlotDef.new(name: "rules", description: "Prolog rules that derive conclusions from facts", format: "can_approve(X) :- role(X, admin), department(X, Dept)."),
        ],
        normalizations: [
          Normalization.new(source: "business rules document", transform: "Extract if-then rules and entity facts into Prolog clauses"),
          Normalization.new(source: "natural language", transform: "Identify entities, properties, and conditional relationships"),
        ],
        tips: [
          "All clauses end with a period. Lowercase is atoms, uppercase is variables",
          "Avoid recursive rules on cyclic data when the solver lacks tabling",
        ]
      ),
      SkillTemplate.new(
        name: "graph-reachability",
        domain: "analysis",
        solver: Solvers::SolverType::Prolog,
        signature: "Check if node A can reach node B through any path in a directed graph - data flow, dependency chains, call graphs, taint analysis",
        skeleton: <<-TEXT,
        % Direct edges in the graph
        {{SLOT:edges}}

        % Direct neighbor query (use for individual checks)
        neighbor(A, B) :- edge(A, B).
        TEXT
        slots: [
          SlotDef.new(name: "edges", description: "Direct edges as edge(from, to) facts", format: "edge(user_input, handler). edge(handler, database)."),
        ],
        normalizations: [
          Normalization.new(source: "import graph", transform: "Map import statements to edge(importer, imported) facts"),
          Normalization.new(source: "data flow", transform: "Map data transformations to edge(source, sink) facts"),
          Normalization.new(source: "call graph", transform: "Map function calls to edge(caller, callee) facts"),
        ],
        tips: [
          "Avoid recursive reaches/2 on cyclic graphs when the solver lacks tabling",
          "For DAGs, recursive reachability is fine; for cyclic graphs, query edges or BFS externally",
        ],
        example: <<-TEXT
        edge(user_input, handler).
        edge(handler, validator).
        edge(validator, database).
        edge(handler, logger).
        neighbor(A, B) :- edge(A, B).
        TEXT
      ),
      SkillTemplate.new(
        name: "permission-derivation",
        domain: "authorization",
        solver: Solvers::SolverType::Prolog,
        signature: "Given a role hierarchy and permission assignments, derive what actions a user can perform on which resources",
        skeleton: <<-TEXT,
        % Role assignments
        {{SLOT:role_assignments}}

        % Role hierarchy (parent inherits child permissions)
        {{SLOT:role_hierarchy}}

        % Permission assignments to roles
        {{SLOT:permissions}}

        % Inheritance logic
        has_role(User, Role) :- role(User, Role).
        has_role(User, Role) :- role(User, R), inherits(R, Role).
        has_role(User, Role) :- role(User, R), inherits(R, Mid), has_role_via(Mid, Role).
        has_role_via(Role, Role).
        has_role_via(Start, End) :- inherits(Start, Mid), has_role_via(Mid, End).

        % Permission check
        can(User, Action, Resource) :- has_role(User, Role), permission(Role, Action, Resource).
        TEXT
        slots: [
          SlotDef.new(name: "role_assignments", description: "Which users have which roles", format: "role(alice, admin). role(bob, editor)."),
          SlotDef.new(name: "role_hierarchy", description: "Role inheritance relationships", format: "inherits(admin, editor). inherits(editor, viewer)."),
          SlotDef.new(name: "permissions", description: "What each role can do", format: "permission(viewer, read, docs). permission(editor, write, docs)."),
        ],
        normalizations: [
          Normalization.new(source: "Django groups and permissions", transform: "Map group to permission assignments to role and permission facts, and group hierarchy to inherits"),
          Normalization.new(source: "Kubernetes RBAC", transform: "Map role bindings to role facts and rules to permission facts"),
        ],
        tips: [
          "Role hierarchy must be acyclic to avoid infinite loops",
          "Query can(alice, Action, Resource) to enumerate derived permissions",
        ]
      ),
    ] of SkillTemplate
  end
end
