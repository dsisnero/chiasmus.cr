module Chiasmus
  module Skills
    record RelatedTemplate,
      name : String,
      reason : String

    RELATIONSHIPS = {
      "policy-contradiction" => [
        RelatedTemplate.new(name: "policy-reachability", reason: "After finding conflicts, verify no principal can escalate to reach conflicting permissions"),
        RelatedTemplate.new(name: "permission-derivation", reason: "Check inherited permissions that may cause the detected contradiction"),
      ],
      "policy-reachability" => [
        RelatedTemplate.new(name: "policy-contradiction", reason: "Reachable policies may contradict each other, so check for allow and deny conflicts"),
        RelatedTemplate.new(name: "permission-derivation", reason: "Derive the full permission set for reachable principals via the role hierarchy"),
      ],
      "permission-derivation" => [
        RelatedTemplate.new(name: "policy-contradiction", reason: "Derived permissions may introduce allow and deny contradictions"),
        RelatedTemplate.new(name: "policy-reachability", reason: "Check whether derived roles can reach sensitive resources"),
      ],
      "schema-consistency" => [
        RelatedTemplate.new(name: "config-equivalence", reason: "Inconsistent schemas may indicate divergent configurations worth comparing"),
        RelatedTemplate.new(name: "constraint-satisfaction", reason: "Check whether the validated constraints can be satisfied simultaneously"),
      ],
      "config-equivalence" => [
        RelatedTemplate.new(name: "schema-consistency", reason: "Equivalent configs should satisfy the same validation rules, so verify consistency"),
      ],
      "constraint-satisfaction" => [
        RelatedTemplate.new(name: "schema-consistency", reason: "Satisfied constraints should align with schema validation rules"),
      ],
      "graph-reachability" => [
        RelatedTemplate.new(name: "rule-inference", reason: "Reachable nodes may trigger inference rules, so derive what follows from the connectivity"),
      ],
      "rule-inference" => [
        RelatedTemplate.new(name: "graph-reachability", reason: "Inferred relationships may create new reachability paths in the dependency graph"),
        RelatedTemplate.new(name: "permission-derivation", reason: "Rule-based derivations often interact with permission and role hierarchies"),
      ],
    }

    def self.get_related_templates(template_name : String) : Array(RelatedTemplate)
      RELATIONSHIPS[template_name]? || [] of RelatedTemplate
    end
  end
end
