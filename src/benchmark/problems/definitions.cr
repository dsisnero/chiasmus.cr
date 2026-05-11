module Benchmark
  module Problems
    RBACRoles     = ["admin", "editor", "viewer", "auditor"]
    RBACResources = ["documents", "settings", "logs", "billing"]
    RBACRules     = [
      {role: "admin", action: "write", resource: "documents", effect: "allow"},
      {role: "admin", action: "read", resource: "billing", effect: "allow"},
      {role: "editor", action: "write", resource: "documents", effect: "allow"},
      {role: "editor", action: "delete", resource: "documents", effect: "deny"},
      {role: "editor", action: "write", resource: "settings", effect: "deny"},
      {role: "auditor", action: "read", resource: "logs", effect: "allow"},
      {role: "auditor", action: "write", resource: "logs", effect: "deny"},
      {role: "auditor", action: "read", resource: "billing", effect: "allow"},
      {role: "auditor", action: "read", resource: "billing", effect: "deny"},
      {role: "viewer", action: "read", resource: "documents", effect: "allow"},
    ]

    PackageConstraints = {
      packages: {
        "app"       => {versions: [1, 2, 3]},
        "framework" => {versions: [2, 3, 4, 5]},
        "database"  => {versions: [1, 2, 3]},
        "cache"     => {versions: [1, 2]},
        "logger"    => {versions: [1, 2, 3]},
      },
      requirements: [
        {package: "app", requires: "framework", minVersion: 3, condition: nil},
        {package: "framework", requires: "database", minVersion: 2, condition: 4},
        {package: "database", requires: "cache", minVersion: 1, condition: nil},
        {package: "cache", requires: "logger", minVersion: 2, condition: 2},
        {package: "app", requires: "logger", minVersion: 3, condition: 3},
      ],
      incompatibilities: [
        {packageA: "framework", versionA: 5, packageB: "database", versionB: 1},
        {packageA: "logger", versionA: 3, packageB: "cache", versionB: 1},
      ],
    }

    DataFlowEdges = [
      {from: "http_request", to: "route_handler"},
      {from: "route_handler", to: "auth_middleware"},
      {from: "route_handler", to: "input_validator"},
      {from: "input_validator", to: "sanitizer"},
      {from: "sanitizer", to: "business_logic"},
      {from: "business_logic", to: "db_query"},
      {from: "business_logic", to: "cache_lookup"},
      {from: "auth_middleware", to: "session_store"},
      {from: "route_handler", to: "logger"},
      {from: "logger", to: "file_write"},
      {from: "route_handler", to: "debug_handler"},
      {from: "debug_handler", to: "eval_engine"},
    ]
    DataFlowSources = ["http_request"]
    DataFlowSinks   = ["db_query", "eval_engine", "file_write"]

    WorkflowInitial = "draft"
    WorkflowStates  = ["draft", "pending_review", "in_review", "approved", "rejected",
                       "published", "archived", "deleted"]
    WorkflowTransitions = [
      {from: "draft", to: "pending_review", action: "submit"},
      {from: "pending_review", to: "in_review", action: "assign_reviewer"},
      {from: "in_review", to: "approved", action: "approve"},
      {from: "in_review", to: "rejected", action: "reject"},
      {from: "rejected", to: "draft", action: "revise"},
      {from: "approved", to: "published", action: "publish"},
      {from: "published", to: "archived", action: "archive"},
    ]

    ValidationFields = {
      "age"             => {type: "integer", values: nil},
      "email_length"    => {type: "integer", values: nil},
      "username_length" => {type: "integer", values: nil},
      "role"            => {type: "enum", values: ["user", "admin", "moderator"]},
    }
    FrontendRules = {
      "age"             => {min: 13, max: 120},
      "email_length"    => {min: 5, max: 254},
      "username_length" => {min: 3, max: 30},
    }
    BackendRules = {
      "age"             => {min: 18, max: 150},
      "email_length"    => {min: 5, max: 320},
      "username_length" => {min: 3, max: 20},
    }
  end
end
