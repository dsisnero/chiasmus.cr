require "spec"
require "file_utils"
require "../../src/chiasmus/plan"
require "../../src/chiasmus/parity"
require "../../src/chiasmus/graph/facts"
require "../../src/chiasmus/graph/ir"

include Chiasmus::Graph

private def sample_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/core.ts", name: "hub", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      DefinesFact.new(file: "src/leaf.ts", name: "leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/unused.ts", name: "unused", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
    ],
    calls: [
      CallsFact.new(caller: "main", callee: "hub"),
      CallsFact.new(caller: "hub", callee: "leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def previous_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/leaf.ts", name: "leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/unused.ts", name: "unused", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
    ],
    calls: [
      CallsFact.new(caller: "main", callee: "leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def duplicate_audit_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/app.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/util.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3)),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def declarative_surface_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/app.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      DefinesFact.new(file: "src/api.ts", name: "ApiShape", kind: SymbolKind::Interface, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/api.ts", name: "ApiAlias", kind: SymbolKind::Type, span: Chiasmus::Graph::Span.line_range(8)),
      DefinesFact.new(file: "src/unused.ts", name: "unused_impl", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
    ],
    calls: [
      CallsFact.new(caller: "main", callee: "helper"),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
      ExportsFact.new(file: "src/api.ts", name: "ApiShape"),
      ExportsFact.new(file: "src/api.ts", name: "ApiAlias"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def multi_file_cleanup_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/app.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      DefinesFact.new(file: "src/cleanup_a.ts", name: "unused_a", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/cleanup_b.ts", name: "unused_b", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
    ],
    calls: [
      CallsFact.new(caller: "main", callee: "helper"),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def multi_file_safe_parallel_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/app.ts", name: "main", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/app.ts", name: "helper", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      DefinesFact.new(file: "src/api_a.ts", name: "ApiShapeA", kind: SymbolKind::Interface, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/api_b.ts", name: "ApiShapeB", kind: SymbolKind::Interface, span: Chiasmus::Graph::Span.line_range(20)),
    ],
    calls: [
      CallsFact.new(caller: "main", callee: "helper"),
    ],
    exports: [
      ExportsFact.new(file: "src/app.ts", name: "main"),
      ExportsFact.new(file: "src/api_a.ts", name: "ApiShapeA"),
      ExportsFact.new(file: "src/api_b.ts", name: "ApiShapeB"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def exported_surface_vs_helper_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/api.ts", name: "api_one", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/api.ts", name: "api_two", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/api.ts", name: "api_three", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
      DefinesFact.new(file: "src/helpers.ts", name: "normalize_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ],
    calls: [
      CallsFact.new(caller: "api_one", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_two", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_three", callee: "normalize_leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/api.ts", name: "api_one"),
      ExportsFact.new(file: "src/api.ts", name: "api_two"),
      ExportsFact.new(file: "src/api.ts", name: "api_three"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def high_centrality_helper_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/api.ts", name: "api_one", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/api.ts", name: "api_two", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/api.ts", name: "api_three", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(20)),
      DefinesFact.new(file: "src/api.ts", name: "api_four", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(30)),
      DefinesFact.new(file: "src/api.ts", name: "api_five", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(40)),
      DefinesFact.new(file: "src/api.ts", name: "api_six", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(50)),
      DefinesFact.new(file: "src/helpers.ts", name: "normalize_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ],
    calls: [
      CallsFact.new(caller: "api_one", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_two", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_three", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_four", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_five", callee: "normalize_leaf"),
      CallsFact.new(caller: "api_six", callee: "normalize_leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/api.ts", name: "api_one"),
      ExportsFact.new(file: "src/api.ts", name: "api_two"),
      ExportsFact.new(file: "src/api.ts", name: "api_three"),
      ExportsFact.new(file: "src/api.ts", name: "api_four"),
      ExportsFact.new(file: "src/api.ts", name: "api_five"),
      ExportsFact.new(file: "src/api.ts", name: "api_six"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def inventory_priority_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/api.ts", name: "missing_api", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/api.ts", name: "ported_api", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/helpers.ts", name: "shared_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ],
    calls: [
      CallsFact.new(caller: "missing_api", callee: "shared_leaf"),
      CallsFact.new(caller: "ported_api", callee: "shared_leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/api.ts", name: "missing_api"),
      ExportsFact.new(file: "src/api.ts", name: "ported_api"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def structural_drift_priority_plan_graph : CodeGraph
  CodeGraph.new(
    defines: [
      DefinesFact.new(file: "src/api.ts", name: "alpha", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "src/api.ts", name: "beta", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
      DefinesFact.new(file: "src/helpers.ts", name: "shared_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ],
    calls: [
      CallsFact.new(caller: "alpha", callee: "shared_leaf"),
      CallsFact.new(caller: "beta", callee: "shared_leaf"),
    ],
    exports: [
      ExportsFact.new(file: "src/api.ts", name: "alpha"),
      ExportsFact.new(file: "src/api.ts", name: "beta"),
    ],
    contains: [] of ContainsFact,
    imports: [] of ImportsFact,
  )
end

private def sample_semantic_plan_graph : Chiasmus::Graph::IR::SemanticGraph
  Chiasmus::Graph::IR::SemanticGraph.new(
    symbols: [
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(1),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/auth.ts::method::Auth.login",
        name: "login",
        qualified_name: "Auth.login",
        owner_name: "Auth",
        kind: SymbolKind::Method,
        file: "src/auth.ts",
        span: Chiasmus::Graph::Span.line_range(10),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/auth.ts::method::Auth.logout",
        name: "logout",
        qualified_name: "Auth.logout",
        owner_name: "Auth",
        kind: SymbolKind::Method,
        file: "src/auth.ts",
        span: Chiasmus::Graph::Span.line_range(20),
      ),
    ],
    calls: [
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "Auth.login"),
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "Auth.logout"),
    ],
    exports: [
      Chiasmus::Graph::IR::ExportEdge.new(file: "src/app.ts", name: "main"),
    ],
    contains: [
      Chiasmus::Graph::IR::ContainsEdge.new(parent: "Auth", child: "Auth.login"),
      Chiasmus::Graph::IR::ContainsEdge.new(parent: "Auth", child: "Auth.logout"),
    ]
  )
end

private def sample_semantic_duplicate_name_plan_graph : Chiasmus::Graph::IR::SemanticGraph
  Chiasmus::Graph::IR::SemanticGraph.new(
    symbols: [
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(1),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::helper",
        name: "helper",
        qualified_name: "helper",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(10),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/util.ts::function::helper",
        name: "helper",
        qualified_name: "helper",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/util.ts",
        span: Chiasmus::Graph::Span.line_range(3),
      ),
    ],
    calls: [
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "helper"),
    ],
    exports: [
      Chiasmus::Graph::IR::ExportEdge.new(file: "src/app.ts", name: "main"),
    ]
  )
end

private def sample_semantic_duplicate_caller_plan_graph : Chiasmus::Graph::IR::SemanticGraph
  Chiasmus::Graph::IR::SemanticGraph.new(
    symbols: [
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(1),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::helper",
        name: "helper",
        qualified_name: "helper",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(10),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::leaf",
        name: "leaf",
        qualified_name: "leaf",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(20),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/util.ts::function::helper",
        name: "helper",
        qualified_name: "helper",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/util.ts",
        span: Chiasmus::Graph::Span.line_range(3),
      ),
    ],
    calls: [
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "helper"),
      Chiasmus::Graph::IR::CallEdge.new(caller: "helper", callee: "leaf"),
    ],
    exports: [
      Chiasmus::Graph::IR::ExportEdge.new(file: "src/app.ts", name: "main"),
    ]
  )
end

private def sample_semantic_duplicate_entry_point_plan_graph : Chiasmus::Graph::IR::SemanticGraph
  Chiasmus::Graph::IR::SemanticGraph.new(
    symbols: [
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(1),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::helper",
        name: "helper",
        qualified_name: "helper",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(10),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/util.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/util.ts",
        span: Chiasmus::Graph::Span.line_range(3),
      ),
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/util.ts::function::orphan",
        name: "orphan",
        qualified_name: "orphan",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/util.ts",
        span: Chiasmus::Graph::Span.line_range(12),
      ),
    ],
    calls: [
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "helper"),
      Chiasmus::Graph::IR::CallEdge.new(caller: "main", callee: "orphan"),
    ],
    exports: [
      Chiasmus::Graph::IR::ExportEdge.new(file: "src/app.ts", name: "main"),
    ]
  )
end

describe Chiasmus::Plan do
  describe Chiasmus::Plan::FeatureGroupIndex do
    it "prefers owner groups only when multiple reports share the owner, otherwise falls back to community then file" do
      reports = [
        Chiasmus::Plan::Report.new(
          name: "Auth.login",
          file: "src/auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 4,
          community_size: 2,
          contains_count: 0,
          priority_score: 10,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
        Chiasmus::Plan::Report.new(
          name: "Auth.logout",
          file: "src/auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 4,
          community_size: 2,
          contains_count: 0,
          priority_score: 9,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
        Chiasmus::Plan::Report.new(
          name: "Solo.run",
          file: "src/solo.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 7,
          community_size: 1,
          contains_count: 0,
          priority_score: 8,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Solo"
        ),
        Chiasmus::Plan::Report.new(
          name: "orphan",
          file: "src/orphan.ts",
          kind: "function",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 0,
          callee_count: 0,
          impact_count: 0,
          hub_degree: 0,
          bridge_score: 0.0,
          community_id: nil,
          community_size: 1,
          contains_count: 0,
          priority_score: 1,
          safety_score: 5,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: nil
        ),
      ]

      groups = Chiasmus::Plan::FeatureGroupIndex.new(reports).groups

      keys = groups.keys
      keys.sort!
      keys.should eq(["community:7", "file:src/orphan.ts", "owner:Auth"])
      groups["owner:Auth"].map(&.name).should eq(["Auth.login", "Auth.logout"])
      groups["community:7"].map(&.name).should eq(["Solo.run"])
      groups["file:src/orphan.ts"].map(&.name).should eq(["orphan"])
    end

    it "disambiguates owner groups when the same owner name appears in multiple files" do
      reports = [
        Chiasmus::Plan::Report.new(
          name: "Auth.login",
          file: "src/auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 4,
          community_size: 2,
          contains_count: 0,
          priority_score: 10,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
        Chiasmus::Plan::Report.new(
          name: "Auth.logout",
          file: "src/auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 4,
          community_size: 2,
          contains_count: 0,
          priority_score: 9,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
        Chiasmus::Plan::Report.new(
          name: "Auth.issue_token",
          file: "src/admin_auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 9,
          community_size: 2,
          contains_count: 0,
          priority_score: 8,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
        Chiasmus::Plan::Report.new(
          name: "Auth.revoke_token",
          file: "src/admin_auth.ts",
          kind: "method",
          reachable_from_entry: true,
          dead_code: false,
          caller_count: 1,
          callee_count: 0,
          impact_count: 1,
          hub_degree: 1,
          bridge_score: 0.0,
          community_id: 9,
          community_size: 2,
          contains_count: 0,
          priority_score: 7,
          safety_score: 1,
          reasons: ["reachable"],
          recommendation: "feature",
          owner_name: "Auth"
        ),
      ]

      groups = Chiasmus::Plan::FeatureGroupIndex.new(reports).groups

      keys = groups.keys
      keys.sort!
      keys.should eq(["owner:Auth@src/admin_auth.ts", "owner:Auth@src/auth.ts"])
      groups["owner:Auth@src/auth.ts"].map(&.name).should eq(["Auth.login", "Auth.logout"])
      groups["owner:Auth@src/admin_auth.ts"].map(&.name).should eq(["Auth.issue_token", "Auth.revoke_token"])
    end
  end

  it "ranks entry-point-reachable hub code ahead of leaves and dead code" do
    reports = Chiasmus::Plan.rank(sample_plan_graph, entry_points: ["main"])

    reports.first.name.should eq("hub")
    reports.map(&.name).index!("main").should be < reports.map(&.name).index!("leaf")
    reports.map(&.name).index!("leaf").should be < reports.map(&.name).index!("unused")

    hub = reports.find { |report| report.name == "hub" } || raise "missing hub report"
    hub.reachable_from_entry.should be_true
    hub.hub_degree.should eq(2)
    hub.reasons.join(" ").downcase.should contain("hub")
  end

  it "ranks dead or weakly connected code as safer work" do
    reports = Chiasmus::Plan.safe(sample_plan_graph, entry_points: ["main"])

    reports.first.name.should eq("unused")
    reports.map(&.name).index!("leaf").should be < reports.map(&.name).index!("hub")

    unused = reports.first
    unused.reachable_from_entry.should be_false
    unused.dead_code.should be_true
    unused.reasons.join(" ").downcase.should contain("dead")
  end

  it "keeps exported reachable surface ahead of private leaf helpers in rank output" do
    reports = Chiasmus::Plan.rank(exported_surface_vs_helper_plan_graph, entry_points: ["api_one", "api_two", "api_three"])

    helper_index = reports.index! { |report| report.name == "normalize_leaf" }
    reports.index! { |report| report.name == "api_one" }.should be < helper_index
    reports.index! { |report| report.name == "api_two" }.should be < helper_index
    reports.index! { |report| report.name == "api_three" }.should be < helper_index

    helper = reports[helper_index]
    helper.reachable_from_entry.should be_true
    helper.recommendation.should eq("feature")
  end

  it "keeps heavily shared private leaf helpers below exported API roots even when centrality is high" do
    reports = Chiasmus::Plan.rank(
      high_centrality_helper_plan_graph,
      entry_points: ["api_one", "api_two", "api_three", "api_four", "api_five", "api_six"]
    )

    helper_index = reports.index! { |report| report.name == "normalize_leaf" }
    reports.first(6).all? { |report| report.file == "src/api.ts" }.should be_true
    helper_index.should eq(6)
  end

  it "prioritizes missing exported inventory rows over shared private helpers" do
    inventory_rows = [
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::missing_api",
        kind: "function",
        status: "missing",
        crystal_refs: "-",
        notes: "Still missing"
      ),
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::ported_api",
        kind: "function",
        status: "ported",
        crystal_refs: "src/api.cr:10",
        notes: "Already ported"
      ),
    ]

    reports = Chiasmus::Plan.rank(
      inventory_priority_plan_graph,
      entry_points: ["missing_api", "ported_api"],
      inventory_rows: inventory_rows
    )

    missing_index = reports.index! { |report| report.name == "missing_api" }
    ported_index = reports.index! { |report| report.name == "ported_api" }
    helper_index = reports.index! { |report| report.name == "shared_leaf" }

    missing_index.should be < helper_index
    missing_index.should be < ported_index
  end

  it "prioritizes structurally drifting ported rows over structurally matched peers when parity data is available" do
    inventory_rows = [
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::alpha",
        kind: "function",
        status: "ported",
        crystal_refs: "src/api.cr:1",
        notes: "Ported"
      ),
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::beta",
        kind: "function",
        status: "ported",
        crystal_refs: "src/api.cr:10",
        notes: "Ported"
      ),
    ]
    parity_rows = [
      Chiasmus::Parity::ReportRow.new(
        source_id: "src/api.ts::function::alpha",
        kind: "function",
        inventory_status: "ported",
        match_status: "curated_alias",
        confidence: 98,
        crystal_name: "alpha",
        crystal_kind: "method",
        crystal_path: "src/api.cr",
        basis: "target_symbol",
        structural_status: "structural_drift",
        structural_details: "missing_calls=shared_leaf",
        notes: "Needs follow-up"
      ),
      Chiasmus::Parity::ReportRow.new(
        source_id: "src/api.ts::function::beta",
        kind: "function",
        inventory_status: "ported",
        match_status: "curated_alias",
        confidence: 98,
        crystal_name: "beta",
        crystal_kind: "method",
        crystal_path: "src/api.cr",
        basis: "target_symbol",
        structural_status: "structural_match",
        structural_details: "-",
        notes: "Looks good"
      ),
    ]

    reports = Chiasmus::Plan.rank(
      structural_drift_priority_plan_graph,
      entry_points: ["alpha", "beta"],
      inventory_rows: inventory_rows,
      parity_rows: parity_rows
    )

    alpha_index = reports.index! { |report| report.name == "alpha" }
    beta_index = reports.index! { |report| report.name == "beta" }

    alpha_index.should be < beta_index
  end

  it "uses repo parity vendor_src to align planner inventory and parity lookups with vendor-prefixed facts" do
    graph = CodeGraph.new(
      defines: [
        DefinesFact.new(file: "./vendor/chiasmus/src/api.ts", name: "alpha", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
        DefinesFact.new(file: "./vendor/chiasmus/src/api.ts", name: "beta", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
        DefinesFact.new(file: "./vendor/chiasmus/src/helpers.ts", name: "shared_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      ],
      calls: [
        CallsFact.new(caller: "alpha", callee: "shared_leaf"),
        CallsFact.new(caller: "beta", callee: "shared_leaf"),
      ],
      exports: [
        ExportsFact.new(file: "./vendor/chiasmus/src/api.ts", name: "alpha"),
        ExportsFact.new(file: "./vendor/chiasmus/src/api.ts", name: "beta"),
      ],
      contains: [] of ContainsFact,
      imports: [] of ImportsFact,
    )
    inventory_rows = [
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::alpha",
        kind: "function",
        status: "ported",
        crystal_refs: "src/api.cr:1",
        notes: "Ported"
      ),
      Chiasmus::Parity::InventoryRow.new(
        source_id: "src/api.ts::function::beta",
        kind: "function",
        status: "ported",
        crystal_refs: "src/api.cr:10",
        notes: "Ported"
      ),
    ]
    parity_rows = [
      Chiasmus::Parity::ReportRow.new(
        source_id: "src/api.ts::function::alpha",
        kind: "function",
        inventory_status: "ported",
        match_status: "curated_alias",
        confidence: 98,
        crystal_name: "alpha",
        crystal_kind: "method",
        crystal_path: "src/api.cr",
        basis: "target_symbol",
        structural_status: "structural_drift",
        structural_details: "missing_calls=shared_leaf",
        notes: "Needs follow-up"
      ),
      Chiasmus::Parity::ReportRow.new(
        source_id: "src/api.ts::function::beta",
        kind: "function",
        inventory_status: "ported",
        match_status: "curated_alias",
        confidence: 98,
        crystal_name: "beta",
        crystal_kind: "method",
        crystal_path: "src/api.cr",
        basis: "target_symbol",
        structural_status: "structural_match",
        structural_details: "-",
        notes: "Looks good"
      ),
    ]
    parity_config = Chiasmus::Utils::Config::RepoParityConfig.new(
      vendor_src: "vendor/chiasmus"
    )

    reports = Chiasmus::Plan.rank(
      graph,
      entry_points: ["alpha", "beta"],
      inventory_rows: inventory_rows,
      parity_rows: parity_rows,
      parity_config: parity_config
    )
    expected = Chiasmus::Plan.rank(
      structural_drift_priority_plan_graph,
      entry_points: ["alpha", "beta"],
      inventory_rows: inventory_rows,
      parity_rows: parity_rows
    )

    reports.map { |report| {report.name, report.priority_score} }.should eq(
      expected.map { |report| {report.name, report.priority_score} }
    )
  end

  it "groups reports into foundational, feature, and cleanup slices" do
    slices = Chiasmus::Plan.slice(sample_plan_graph, entry_points: ["main"])

    slices.map(&.slice_kind).should contain("foundational")
    slices.map(&.slice_kind).should contain("feature")
    slices.map(&.slice_kind).should contain("cleanup")

    foundational = slices.find { |slice| slice.slice_kind == "foundational" } || raise "missing foundational slice"
    foundational.members.map(&.name).should eq(["hub"])
    foundational.parallel_safe.should be_false

    cleanup = slices.find { |slice| slice.slice_kind == "cleanup" } || raise "missing cleanup slice"
    cleanup.members.map(&.name).should eq(["unused"])
    cleanup.parallel_safe.should be_true

    feature = slices.find { |slice| slice.slice_kind == "feature" } || raise "missing feature slice"
    feature.members.map(&.name).should eq(["leaf", "main"])
  end

  it "does not classify declarative interface and type surface as cleanup solely because they are isolated" do
    reports = Chiasmus::Plan.safe(declarative_surface_plan_graph, entry_points: ["main"])

    api_shape = reports.find { |report| report.name == "ApiShape" } || raise "missing ApiShape report"
    api_alias = reports.find { |report| report.name == "ApiAlias" } || raise "missing ApiAlias report"
    unused_impl = reports.find { |report| report.name == "unused_impl" } || raise "missing unused_impl report"

    api_shape.dead_code.should be_false
    api_shape.recommendation.should eq("safe_parallel")
    api_alias.dead_code.should be_false
    api_alias.recommendation.should eq("safe_parallel")
    unused_impl.dead_code.should be_true
    unused_impl.recommendation.should eq("cleanup")

    slices = Chiasmus::Plan.slice(declarative_surface_plan_graph, entry_points: ["main"])
    cleanup = slices.find { |slice| slice.slice_kind == "cleanup" } || raise "missing cleanup slice"
    cleanup.members.map(&.name).should eq(["unused_impl"])

    safe_parallel = slices.find { |slice| slice.slice_kind == "safe_parallel" } || raise "missing safe parallel slice"
    safe_parallel.members.map(&.name).should eq(["ApiAlias", "ApiShape"])
  end

  it "splits cleanup work into file-sized slices instead of one giant dead-code bucket" do
    slices = Chiasmus::Plan.slice(multi_file_cleanup_plan_graph, entry_points: ["main"])
    cleanup = slices.select { |slice| slice.slice_kind == "cleanup" }

    cleanup.map(&.slice_id).sort!.should eq([
      "cleanup:file:src/cleanup_a.ts",
      "cleanup:file:src/cleanup_b.ts",
    ])

    cleanup.find(&.slice_id.==("cleanup:file:src/cleanup_a.ts")).not_nil!.members.map(&.name).should eq(["unused_a"])
    cleanup.find(&.slice_id.==("cleanup:file:src/cleanup_b.ts")).not_nil!.members.map(&.name).should eq(["unused_b"])
  end

  it "splits safe parallel work into file-sized slices instead of one giant batch" do
    slices = Chiasmus::Plan.slice(multi_file_safe_parallel_plan_graph, entry_points: ["main"])
    safe_parallel = slices.select { |slice| slice.slice_kind == "safe_parallel" }

    safe_parallel.map(&.slice_id).sort!.should eq([
      "safe-parallel:file:src/api_a.ts",
      "safe-parallel:file:src/api_b.ts",
    ])

    safe_parallel.find(&.slice_id.==("safe-parallel:file:src/api_a.ts")).not_nil!.members.map(&.name).should eq(["ApiShapeA"])
    safe_parallel.find(&.slice_id.==("safe-parallel:file:src/api_b.ts")).not_nil!.members.map(&.name).should eq(["ApiShapeB"])
  end

  it "generates a markdown seed parity plan from slices" do
    seed = Chiasmus::Plan.seed_parity(sample_plan_graph, entry_points: ["main"])

    seed.should contain("# Seed Parity Plan")
    seed.should contain("## Proposed Foundational Work")
    seed.should contain("## Proposed Feature Work")
    seed.should contain("## Proposed Cleanup Or Deferred Work")
    seed.should contain("foundational:hub")
    seed.should contain("community:0")
    seed.should contain("cleanup:dead-code")
    seed.should contain("Members: `hub`")
    seed.should contain("Members: `leaf`, `main`")
    seed.should contain("Status: `proposed`")
  end

  it "tracks curated slice status from a parity markdown plan" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-track-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      parity_plan_path = File.join(dir, "parity.md")
      File.write(parity_plan_path, <<-MD)
        # Parity Plan

        ## Accepted Work

        ### `foundational:hub`

        - Status: `accepted`

        ### `community:0`

        - Status: `in_progress`
      MD

      tracked = Chiasmus::Plan.track(sample_plan_graph, parity_plan_path: parity_plan_path, entry_points: ["main"])

      tracked.map(&.accepted_status).should contain("accepted")
      tracked.map(&.accepted_status).should contain("in_progress")
      tracked.map(&.accepted_status).should contain("proposed")

      foundational = tracked.find { |slice| slice.slice_id == "foundational:hub" } || raise "missing foundational tracked slice"
      foundational.accepted_status.should eq("accepted")

      feature = tracked.find { |slice| slice.slice_id == "community:0" } || raise "missing feature tracked slice"
      feature.accepted_status.should eq("in_progress")

      cleanup = tracked.find { |slice| slice.slice_id == "cleanup:dead-code" } || raise "missing cleanup tracked slice"
      cleanup.accepted_status.should eq("proposed")
      cleanup.parallel_safe.should be_true
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "audits a symbol with explainable ranking details" do
    report = Chiasmus::Plan.audit(sample_plan_graph, symbol: "hub", entry_points: ["main"])

    report.name.should eq("hub")
    report.recommendation.should eq("foundational")
    report.reachable_from_entry.should be_true
    report.hub_degree.should eq(2)
    report.reasons.join(" ").should contain("reachable from entry point")
  end

  it "audits only the requested report instead of analyzing every symbol" do
    analyzed = [] of String

    begin
      Chiasmus::Plan.set_after_report_analyzed_hook_for_test do |name|
        analyzed << name
      end

      report = Chiasmus::Plan.audit(sample_plan_graph, symbol: "hub", entry_points: ["main"])

      report.name.should eq("hub")
      analyzed.should eq(["hub"])
    ensure
      Chiasmus::Plan.clear_after_report_analyzed_hook_for_test
    end
  end

  it "requires a file hint when auditing duplicate semantic-ir names" do
    expect_raises(Exception, /Ambiguous symbol: helper/) do
      Chiasmus::Plan.audit(sample_semantic_duplicate_name_plan_graph, symbol: "helper", entry_points: ["main"])
    end

    report = Chiasmus::Plan.audit(
      sample_semantic_duplicate_name_plan_graph,
      symbol: "helper",
      file: "src/util.ts",
      entry_points: ["main"]
    )

    report.file.should eq("src/util.ts")
    report.reachable_from_entry.should be_false
    report.dead_code.should be_true
  end

  it "refreshes only changed or newly risky slices from a previous facts snapshot" do
    refreshed = Chiasmus::Plan.refresh(sample_plan_graph, previous_graph: previous_plan_graph, entry_points: ["main"])

    refreshed.map(&.slice_id).should contain("foundational:hub")
    refreshed.map(&.slice_id).should_not contain("cleanup:dead-code")

    new_slice = refreshed.find { |slice| slice.slice_id == "foundational:hub" } || raise "missing refresh for hub"
    new_slice.change_kind.should eq("new_slice")
    new_slice.accepted_status.should eq("proposed")
  end

  it "groups semantic-ir feature work by owner when related methods share the same container" do
    slices = Chiasmus::Plan.slice(sample_semantic_plan_graph, entry_points: ["main"])

    owner_slice = slices.find { |slice| slice.slice_id == "owner:Auth" } || raise "missing owner feature slice"
    owner_slice.slice_kind.should eq("feature")
    owner_slice.members.map(&.name).should eq(["Auth.login", "Auth.logout"])

    seed = Chiasmus::Plan.seed_parity(sample_semantic_plan_graph, entry_points: ["main"])
    seed.should contain("owner:Auth")
    seed.should contain("Members: `Auth.login`, `Auth.logout`")
  end

  it "keeps duplicate semantic-ir names file-scoped when ranking reachability" do
    reports = Chiasmus::Plan.rank(sample_semantic_duplicate_name_plan_graph, entry_points: ["main"])
    helper_reports = reports.select { |report| report.name == "helper" }

    helper_reports.size.should eq(2)

    app_helper = helper_reports.find { |report| report.file == "src/app.ts" } || raise "missing app helper report"
    util_helper = helper_reports.find { |report| report.file == "src/util.ts" } || raise "missing util helper report"

    app_helper.reachable_from_entry.should be_true
    app_helper.dead_code.should be_false
    util_helper.reachable_from_entry.should be_false
    util_helper.dead_code.should be_true
  end

  it "does not let ambiguous duplicate callers borrow global callees from another file" do
    reports = Chiasmus::Plan.rank(sample_semantic_duplicate_caller_plan_graph, entry_points: ["main"])

    app_helper = reports.find { |report| report.name == "helper" && report.file == "src/app.ts" } || raise "missing app helper report"
    util_helper = reports.find { |report| report.name == "helper" && report.file == "src/util.ts" } || raise "missing util helper report"
    leaf = reports.find { |report| report.name == "leaf" && report.file == "src/app.ts" } || raise "missing leaf report"

    app_helper.reachable_from_entry.should be_true
    app_helper.callee_count.should eq(1)
    util_helper.reachable_from_entry.should be_false
    util_helper.callee_count.should eq(0)
    leaf.caller_count.should eq(1)
  end

  it "resolves duplicate explicit semantic entry points through export ownership before name fallback" do
    reports = Chiasmus::Plan.rank(sample_semantic_duplicate_entry_point_plan_graph, entry_points: ["main"])

    app_main = reports.find { |report| report.name == "main" && report.file == "src/app.ts" } || raise "missing app main report"
    util_main = reports.find { |report| report.name == "main" && report.file == "src/util.ts" } || raise "missing util main report"
    helper = reports.find { |report| report.name == "helper" && report.file == "src/app.ts" } || raise "missing helper report"
    orphan = reports.find { |report| report.name == "orphan" && report.file == "src/util.ts" } || raise "missing orphan report"

    app_main.reachable_from_entry.should be_true
    util_main.reachable_from_entry.should be_false
    helper.reachable_from_entry.should be_true
    orphan.reachable_from_entry.should be_false
  end
end

it "normalizes semantic graphs only once when seeding a parity plan" do
  semantic = Chiasmus::Graph::IR::SemanticGraph.new(
    symbols: [
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "src/app.ts::function::main",
        name: "main",
        qualified_name: "main",
        owner_name: nil,
        kind: SymbolKind::Function,
        file: "src/app.ts",
        span: Chiasmus::Graph::Span.line_range(1),
      ),
    ],
    exports: [
      Chiasmus::Graph::IR::ExportEdge.new(file: "src/app.ts", name: "main"),
    ],
  )

  normalize_count = 0
  begin
    Chiasmus::Graph::IR.set_before_normalize_semantic_hook_for_test do
      normalize_count += 1
    end

    seed = Chiasmus::Plan.seed_parity(semantic, ["main"], 10)
    seed.should contain("# Seed Parity Plan")
    normalize_count.should eq(1)
  ensure
    Chiasmus::Graph::IR.clear_before_normalize_semantic_hook_for_test
  end
end

describe Chiasmus::Plan::CLI do
  it "reads facts and emits ranked TSV output for planner modes" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(facts_path, Chiasmus::Graph::Facts.graph_to_prolog(sample_plan_graph, ["main"], include_insights: true))

      rank_output = IO::Memory.new
      rank_error = IO::Memory.new
      rank_exit = Chiasmus::Plan::CLI.run(["rank", "--facts", facts_path, "--format", "tsv"], rank_output, rank_error)

      rank_exit.should eq(0), rank_error.to_s
      rank_text = rank_output.to_s
      rank_text.should contain("# mode=rank")
      rank_text.should contain("hub")
      rank_text.should contain("unused")

      safe_output = IO::Memory.new
      safe_error = IO::Memory.new
      safe_exit = Chiasmus::Plan::CLI.run(["safe", "--facts", facts_path, "--format", "tsv"], safe_output, safe_error)

      safe_exit.should eq(0), safe_error.to_s
      safe_output.to_s.should contain("# mode=safe")
      safe_output.to_s.lines[2].should contain("unused")

      slice_output = IO::Memory.new
      slice_error = IO::Memory.new
      slice_exit = Chiasmus::Plan::CLI.run(["slice", "--facts", facts_path, "--format", "tsv"], slice_output, slice_error)

      slice_exit.should eq(0), slice_error.to_s
      slice_text = slice_output.to_s
      slice_text.should contain("# mode=slice")
      slice_text.should contain("foundational")
      slice_text.should contain("cleanup")

      seed_output = IO::Memory.new
      seed_error = IO::Memory.new
      seed_exit = Chiasmus::Plan::CLI.run(["seed-parity", "--facts", facts_path], seed_output, seed_error)

      seed_exit.should eq(0), seed_error.to_s
      seed_text = seed_output.to_s
      seed_text.should contain("# Seed Parity Plan")
      seed_text.should contain("## Proposed Foundational Work")
      seed_text.should contain("cleanup:dead-code")

      seed_file = File.join(dir, "seed_parity.md")
      file_output = IO::Memory.new
      file_error = IO::Memory.new
      file_exit = Chiasmus::Plan::CLI.run(["seed-parity", "--facts", facts_path, "--out", seed_file], file_output, file_error)

      file_exit.should eq(0), file_error.to_s
      file_output.to_s.should eq("")
      File.read(seed_file).should contain("# Seed Parity Plan")
      File.read(seed_file).should contain("## Proposed Feature Work")

      parity_plan_path = File.join(dir, "parity.md")
      File.write(parity_plan_path, <<-MD)
        # Parity Plan

        ### `foundational:hub`

        - Status: `accepted`
      MD

      track_output = IO::Memory.new
      track_error = IO::Memory.new
      track_exit = Chiasmus::Plan::CLI.run(["track", "--facts", facts_path, "--parity-plan", parity_plan_path, "--format", "tsv"], track_output, track_error)

      track_exit.should eq(0), track_error.to_s
      track_text = track_output.to_s
      track_text.should contain("# mode=track")
      track_text.should contain("foundational:hub")
      track_text.should contain("accepted")
      track_text.should contain("cleanup:dead-code")

      audit_output = IO::Memory.new
      audit_error = IO::Memory.new
      audit_exit = Chiasmus::Plan::CLI.run(["audit", "--facts", facts_path, "--symbol", "hub"], audit_output, audit_error)

      audit_exit.should eq(0), audit_error.to_s
      audit_text = audit_output.to_s
      audit_text.should contain("# Audit: `hub`")
      audit_text.should contain("Recommendation: `foundational`")
      audit_text.should contain("Priority score")
      audit_text.should contain("hub degree 2")

      previous_facts_path = File.join(dir, "vendor_previous.pl")
      File.write(previous_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(previous_plan_graph, ["main"], include_insights: true))

      refresh_output = IO::Memory.new
      refresh_error = IO::Memory.new
      refresh_exit = Chiasmus::Plan::CLI.run(["refresh", "--facts", facts_path, "--previous-facts", previous_facts_path, "--format", "tsv"], refresh_output, refresh_error)

      refresh_exit.should eq(0), refresh_error.to_s
      refresh_text = refresh_output.to_s
      refresh_text.should contain("# mode=refresh")
      refresh_text.should contain("foundational:hub")
      refresh_text.should contain("new_slice")
      refresh_text.should_not contain("cleanup:dead-code")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "disambiguates audit symbols by file when duplicate names exist" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-audit-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(facts_path, Chiasmus::Graph::Facts.graph_to_prolog(duplicate_audit_plan_graph, ["main"], include_insights: true))

      ambiguous_output = IO::Memory.new
      ambiguous_error = IO::Memory.new
      ambiguous_exit = Chiasmus::Plan::CLI.run(["audit", "--facts", facts_path, "--symbol", "helper"], ambiguous_output, ambiguous_error)

      ambiguous_exit.should eq(1)
      ambiguous_error.to_s.should contain("Ambiguous symbol: helper")

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(
        ["audit", "--facts", facts_path, "--symbol", "helper", "--file", "src/util.ts"],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should contain("File: `src/util.ts`")
      output.to_s.should contain("Audit: `helper`")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses reconstructed semantic facts to keep duplicate entry points file-scoped" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-semantic-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(
        facts_path,
        Chiasmus::Graph::Facts.graph_to_prolog(sample_semantic_duplicate_entry_point_plan_graph, ["main"], include_insights: true)
      )

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(["rank", "--facts", facts_path, "--format", "json"], output, error)

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      app_main = reports.find { |report| report.as_h["name"].as_s == "main" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing app main report"
      util_main = reports.find { |report| report.as_h["name"].as_s == "main" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing util main report"
      orphan = reports.find { |report| report.as_h["name"].as_s == "orphan" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing orphan report"

      app_main.as_h["reachable_from_entry"].as_bool.should be_true
      util_main.as_h["reachable_from_entry"].as_bool.should be_false
      orphan.as_h["reachable_from_entry"].as_bool.should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "honors file-scoped entry-point facts when duplicate roots exist" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-entry-point-file-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(facts_path, <<-PROLOG)
        defines('src/app.ts', main, function, 1, 0).
        defines('src/app.ts', helper, function, 10, 0).
        defines('src/util.ts', main, function, 3, 0).
        defines('src/util.ts', orphan, function, 12, 0).

        calls(main, helper).
        calls(main, orphan).

        entry_point(main).
        entry_point_file('src/app.ts', main).
      PROLOG

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(["rank", "--facts", facts_path, "--format", "json"], output, error)

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      app_main = reports.find { |report| report.as_h["name"].as_s == "main" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing app main report"
      util_main = reports.find { |report| report.as_h["name"].as_s == "main" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing util main report"
      helper = reports.find { |report| report.as_h["name"].as_s == "helper" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing helper report"
      orphan = reports.find { |report| report.as_h["name"].as_s == "orphan" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing orphan report"

      app_main.as_h["reachable_from_entry"].as_bool.should be_true
      util_main.as_h["reachable_from_entry"].as_bool.should be_false
      helper.as_h["reachable_from_entry"].as_bool.should be_true
      orphan.as_h["reachable_from_entry"].as_bool.should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses file-scoped call facts to avoid cross-file duplicate caller drift" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-calls-in-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(facts_path, <<-PROLOG)
        defines('src/app.ts', main, function, 1, 0).
        defines('src/app.ts', helper, function, 10, 0).
        defines('src/app.ts', leaf, function, 20, 0).
        defines('src/util.ts', helper, function, 3, 0).

        calls(main, helper).
        calls(helper, leaf).
        calls_in('src/app.ts', main, helper).
        calls_in('src/app.ts', helper, leaf).

        entry_point(main).
        entry_point_file('src/app.ts', main).
      PROLOG

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(["rank", "--facts", facts_path, "--format", "json"], output, error)

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      app_helper = reports.find { |report| report.as_h["name"].as_s == "helper" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing app helper report"
      util_helper = reports.find { |report| report.as_h["name"].as_s == "helper" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing util helper report"
      leaf = reports.find { |report| report.as_h["name"].as_s == "leaf" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing leaf report"

      app_helper.as_h["callee_count"].as_i.should eq(1)
      util_helper.as_h["callee_count"].as_i.should eq(0)
      leaf.as_h["caller_count"].as_i.should eq(1)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "respects calls_in/3 to avoid over-assigning when callee name collides across files" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-calls-in-collide-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      File.write(facts_path, <<-PROLOG)
        defines('src/app.ts', helper, function, 10, 0).
        defines('src/app.ts', leaf, function, 20, 0).
        defines('src/util.ts', helper, function, 3, 0).
        defines('src/util.ts', leaf, function, 5, 0).

        calls(helper, leaf).
        calls_in('src/app.ts', helper, leaf).

        entry_point(helper).
        entry_point_file('src/app.ts', helper).
      PROLOG

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(["rank", "--facts", facts_path, "--format", "json"], output, error)

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      app_helper = reports.find { |report| report.as_h["name"].as_s == "helper" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing app helper"
      util_helper = reports.find { |report| report.as_h["name"].as_s == "helper" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing util helper"
      app_leaf = reports.find { |report| report.as_h["name"].as_s == "leaf" && report.as_h["file"].as_s == "src/app.ts" } || raise "missing app leaf"
      util_leaf = reports.find { |report| report.as_h["name"].as_s == "leaf" && report.as_h["file"].as_s == "src/util.ts" } || raise "missing util leaf"

      app_helper.as_h["callee_count"].as_i.should eq(1)
      util_helper.as_h["callee_count"].as_i.should eq(0)
      app_leaf.as_h["caller_count"].as_i.should eq(1)
      util_leaf.as_h["caller_count"].as_i.should eq(0)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses inventory and parity report input to reprioritize structurally drifting rows in CLI rank output" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-cli-parity-rank-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      facts_path = File.join(dir, "vendor.pl")
      inventory_path = File.join(dir, "inventory.tsv")
      parity_path = File.join(dir, "parity.tsv")

      File.write(facts_path, Chiasmus::Graph::Facts.graph_to_prolog(structural_drift_priority_plan_graph, ["alpha", "beta"], include_insights: true))
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/api.ts::function::alpha	function	ported	src/api.cr:1	alpha	-	Ported
src/api.ts::function::beta	function	ported	src/api.cr:10	beta	-	Ported
TSV
      File.write(parity_path, <<-TSV)
# parser_mode=regex
# source_id	kind	inventory_status	match_status	confidence	crystal_name	crystal_kind	crystal_path	basis	structural_status	structural_details	notes
src/api.ts::function::alpha	function	ported	curated_alias	98	alpha	method	src/api.cr	target_symbol	structural_drift	missing_calls=shared_leaf	Needs follow-up
src/api.ts::function::beta	function	ported	curated_alias	98	beta	method	src/api.cr	target_symbol	structural_match	-	Looks good
TSV

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(
        ["rank", "--facts", facts_path, "--inventory", inventory_path, "--parity-report", parity_path, "--format", "json"],
        output,
        error
      )

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      reports[0].as_h["name"].as_s.should eq("alpha")
      reports[1].as_h["name"].as_s.should eq("beta")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses repo parity vendor_src config through an explicit CLI --root when facts use vendor-prefixed paths" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-cli-root-#{Random::Secure.hex(8)}")
    repo_root = File.join(dir, "repo")
    facts_path = File.join(dir, "vendor.pl")
    inventory_path = File.join(dir, "inventory.tsv")
    parity_path = File.join(dir, "parity.tsv")
    Dir.mkdir_p(repo_root)

    begin
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "./vendor/chiasmus/src/api.ts", name: "alpha", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
          DefinesFact.new(file: "./vendor/chiasmus/src/api.ts", name: "beta", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(10)),
          DefinesFact.new(file: "./vendor/chiasmus/src/helpers.ts", name: "shared_leaf", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
        ],
        calls: [
          CallsFact.new(caller: "alpha", callee: "shared_leaf"),
          CallsFact.new(caller: "beta", callee: "shared_leaf"),
        ],
        exports: [
          ExportsFact.new(file: "./vendor/chiasmus/src/api.ts", name: "alpha"),
          ExportsFact.new(file: "./vendor/chiasmus/src/api.ts", name: "beta"),
        ],
        contains: [] of ContainsFact,
        imports: [] of ImportsFact,
      )

      File.write(facts_path, Chiasmus::Graph::Facts.graph_to_prolog(graph, ["alpha", "beta"], include_insights: true))
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/api.ts::function::alpha	function	ported	src/api.cr:1	alpha	-	Ported
src/api.ts::function::beta	function	ported	src/api.cr:10	beta	-	Ported
TSV
      File.write(parity_path, <<-TSV)
# parser_mode=regex
# source_id	kind	inventory_status	match_status	confidence	crystal_name	crystal_kind	crystal_path	basis	structural_status	structural_details	notes
src/api.ts::function::alpha	function	ported	curated_alias	98	alpha	method	src/api.cr	target_symbol	structural_drift	missing_calls=shared_leaf	Needs follow-up
src/api.ts::function::beta	function	ported	curated_alias	98	beta	method	src/api.cr	target_symbol	structural_match	-	Looks good
TSV

      Chiasmus::Utils::Config.ensure_repo_parity_config(
        vendor_src: "vendor/chiasmus",
        target_src: ["src"],
        repo_root: repo_root
      )

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Plan::CLI.run(
        ["rank", "--facts", facts_path, "--inventory", inventory_path, "--parity-report", parity_path, "--root", repo_root, "--format", "json"],
        output,
        error
      )

      exit_code.should eq(0), error.to_s

      reports = JSON.parse(output.to_s).as_h["reports"].as_a
      reports[0].as_h["name"].as_s.should eq("alpha")
      reports[1].as_h["name"].as_s.should eq("beta")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
