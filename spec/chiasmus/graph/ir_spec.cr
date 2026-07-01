require "../../spec_helper"

class IRSuffixRefiner < Chiasmus::Graph::IR::Refiner
  def initialize(@suffix : String)
  end

  def refine(graph : Chiasmus::Graph::IR::SemanticGraph) : Chiasmus::Graph::IR::SemanticGraph
    refined = graph.symbols.map do |symbol|
      Chiasmus::Graph::IR::SymbolNode.new(
        id: "#{symbol.id}#{@suffix}",
        name: symbol.name,
        qualified_name: symbol.qualified_name,
        owner_name: symbol.owner_name,
        kind: symbol.kind,
        file: symbol.file,
        line: symbol.line,
        end_line: symbol.end_line,
        signature: symbol.signature,
      )
    end

    Chiasmus::Graph::IR::SemanticGraph.new(
      files: graph.files,
      symbols: refined,
      calls: graph.calls,
      imports: graph.imports,
      exports: graph.exports,
      contains: graph.contains,
      type_info: graph.type_info,
    )
  end
end

class IRContainsFilterRefiner < Chiasmus::Graph::IR::Refiner
  def refine(graph : Chiasmus::Graph::IR::SemanticGraph) : Chiasmus::Graph::IR::SemanticGraph
    refined_contains = graph.contains.reject { |edge| edge.parent == edge.child }

    Chiasmus::Graph::IR::SemanticGraph.new(
      files: graph.files,
      symbols: graph.symbols,
      calls: graph.calls,
      imports: graph.imports,
      exports: graph.exports,
      contains: refined_contains,
      type_info: graph.type_info,
    )
  end
end

describe Chiasmus::Graph::IR do
  describe Chiasmus::Graph::IR::Lowering do
    it "derives stable symbol ids and owner names from qualified names" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "src/service.ts",
            name: "UserService.fetch",
            kind: Chiasmus::Graph::SymbolKind::Method,
            line: 10,
            end_line: 12
          ),
        ]
      )

      semantic = Chiasmus::Graph::IR::Lowering.from_code_graph(graph)
      symbol = semantic.symbols.first

      symbol.id.should eq("src/service.ts::method::UserService.fetch")
      symbol.name.should eq("fetch")
      symbol.qualified_name.should eq("UserService.fetch")
      symbol.owner_name.should eq("UserService")
    end

    it "round-trips CodeGraph through the semantic graph without losing facts" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "src/app.ts",
            name: "main",
            kind: Chiasmus::Graph::SymbolKind::Function,
            line: 1,
            end_line: 3
          ),
          Chiasmus::Graph::DefinesFact.new(
            file: "src/service.ts",
            name: "UserService.fetch",
            kind: Chiasmus::Graph::SymbolKind::Method,
            line: 4,
            end_line: 8,
            signature: "fetch(id: string)"
          ),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new("main", "UserService.fetch", "UserService.fetch"),
        ],
        imports: [
          Chiasmus::Graph::ImportsFact.new("src/app.ts", "UserService", "./service"),
        ],
        exports: [
          Chiasmus::Graph::ExportsFact.new("src/app.ts", "main"),
        ],
        contains: [
          Chiasmus::Graph::ContainsFact.new("UserService", "UserService.fetch"),
        ],
        files: [
          Chiasmus::Graph::FileNode.new("src/app.ts", "typescript", 20, 80, "entry point"),
        ],
        type_info: [
          Chiasmus::Graph::FileTypeInfo.new("src/app.ts"),
        ]
      )

      semantic = Chiasmus::Graph::IR::Lowering.from_code_graph(graph)
      round_trip = Chiasmus::Graph::IR::Lowering.to_code_graph(semantic)

      round_trip.should eq(graph)
    end
  end

  describe Chiasmus::Graph::IR::Pipeline do
    it "applies refiners in order" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "src/app.ts::function::main",
            name: "main",
            qualified_name: "main",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Function,
            file: "src/app.ts",
            line: 1
          ),
        ]
      )

      pipeline = Chiasmus::Graph::IR::Pipeline.new([
        IRSuffixRefiner.new(":a"),
        IRSuffixRefiner.new(":b"),
      ] of Chiasmus::Graph::IR::Refiner)

      refined = pipeline.refine(graph)
      refined.symbols.first.id.should eq("src/app.ts::function::main:a:b")
    end

    it "returns a closed channel after async refinement" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService"),
          Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService.fetch"),
        ]
      )

      pipeline = Chiasmus::Graph::IR::Pipeline.new([
        IRContainsFilterRefiner.new,
      ] of Chiasmus::Graph::IR::Refiner)

      result_channel = pipeline.refine_async(graph)
      refined = result_channel.receive?

      refined.should_not be_nil
      value = refined || raise "expected refined semantic graph"
      value.contains.should eq([
        Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService.fetch"),
      ])
      result_channel.receive?.should be_nil
    end
  end

  describe ".normalize" do
    it "repairs symbol identity and removes duplicate structural edges" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        files: [
          Chiasmus::Graph::IR::FileNode.new("src/service.ts", "typescript"),
          Chiasmus::Graph::IR::FileNode.new("src/service.ts", "typescript"),
        ],
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "wrong",
            name: "wrong",
            qualified_name: "UserService.fetch",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service.ts",
            line: 10
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "duplicate",
            name: "fetch",
            qualified_name: "UserService.fetch",
            owner_name: "UserService",
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service.ts",
            line: 10
          ),
        ],
        calls: [
          Chiasmus::Graph::IR::CallEdge.new("main", "UserService.fetch"),
          Chiasmus::Graph::IR::CallEdge.new("main", "UserService.fetch"),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService"),
          Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService.fetch"),
          Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService.fetch"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.files.size.should eq(1)
      normalized.symbols.size.should eq(1)
      symbol = normalized.symbols.first
      symbol.id.should eq("src/service.ts::method::UserService.fetch")
      symbol.name.should eq("fetch")
      symbol.owner_name.should eq("UserService")
      normalized.calls.size.should eq(1)
      normalized.contains.should eq([
        Chiasmus::Graph::IR::ContainsEdge.new("UserService", "UserService.fetch"),
      ])
    end

    it "qualifies contained symbols and rewrites related edges consistently" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "wrong-class",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "wrong-method",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/config.cr",
            line: 4
          ),
        ],
        calls: [
          Chiasmus::Graph::IR::CallEdge.new("load", "helper", nil),
          Chiasmus::Graph::IR::CallEdge.new("main", "load", "load"),
        ],
        exports: [
          Chiasmus::Graph::IR::ExportEdge.new("src/config.cr", "load"),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.symbols.map(&.qualified_name).should eq(["Config", "Config.load"])
      normalized.calls.should eq([
        Chiasmus::Graph::IR::CallEdge.new("Config.load", "helper", nil),
        Chiasmus::Graph::IR::CallEdge.new("main", "Config.load", "Config.load"),
      ])
      normalized.exports.should eq([
        Chiasmus::Graph::IR::ExportEdge.new("src/config.cr", "Config.load"),
      ])
      normalized.contains.should eq([
        Chiasmus::Graph::IR::ContainsEdge.new("Config", "Config.load"),
      ])
    end

    it "qualifies nested containment transitively" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo",
            name: "Demo",
            qualified_name: "Demo",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/config.cr",
            line: 4
          ),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.symbols.map(&.qualified_name).should eq([
        "Demo",
        "Demo.Config",
        "Demo.Config.load",
      ])
      normalized.contains.should eq([
        Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Demo.Config"),
        Chiasmus::Graph::IR::ContainsEdge.new("Demo.Config", "Demo.Config.load"),
      ])
    end

    it "qualifies repeated nested containment independently per file" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo",
            name: "Demo",
            qualified_name: "Demo",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/demo_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/demo_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/demo_config.cr",
            line: 4
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service",
            name: "Service",
            qualified_name: "Service",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/service_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/service_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service_config.cr",
            line: 4
          ),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
          Chiasmus::Graph::IR::ContainsEdge.new("Service", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.symbols.map(&.qualified_name).should eq([
        "Demo",
        "Demo.Config",
        "Demo.Config.load",
        "Service",
        "Service.Config",
        "Service.Config.load",
      ])
      normalized.contains.should eq([
        Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Demo.Config"),
        Chiasmus::Graph::IR::ContainsEdge.new("Demo.Config", "Demo.Config.load"),
        Chiasmus::Graph::IR::ContainsEdge.new("Service", "Service.Config"),
        Chiasmus::Graph::IR::ContainsEdge.new("Service.Config", "Service.Config.load"),
      ])
    end

    it "rewrites repeated contained call edges independently per file" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo",
            name: "Demo",
            qualified_name: "Demo",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/demo_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/demo_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/demo_config.cr",
            line: 4
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-helper",
            name: "helper",
            qualified_name: "helper",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/demo_config.cr",
            line: 6
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service",
            name: "Service",
            qualified_name: "Service",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/service_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/service_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service_config.cr",
            line: 4
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-helper",
            name: "helper",
            qualified_name: "helper",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service_config.cr",
            line: 6
          ),
        ],
        calls: [
          Chiasmus::Graph::IR::CallEdge.new("load", "helper"),
          Chiasmus::Graph::IR::CallEdge.new("load", "helper"),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "helper"),
          Chiasmus::Graph::IR::ContainsEdge.new("Service", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "helper"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.calls.should eq([
        Chiasmus::Graph::IR::CallEdge.new("Demo.Config.load", "Demo.Config.helper"),
        Chiasmus::Graph::IR::CallEdge.new("Service.Config.load", "Service.Config.helper"),
      ])
    end

    it "rewrites repeated contained export edges independently per file" do
      graph = Chiasmus::Graph::IR::SemanticGraph.new(
        symbols: [
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo",
            name: "Demo",
            qualified_name: "Demo",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/demo_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/demo_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "demo-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/demo_config.cr",
            line: 4
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service",
            name: "Service",
            qualified_name: "Service",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Module,
            file: "src/service_config.cr",
            line: 1
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-config",
            name: "Config",
            qualified_name: "Config",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Class,
            file: "src/service_config.cr",
            line: 2
          ),
          Chiasmus::Graph::IR::SymbolNode.new(
            id: "service-load",
            name: "load",
            qualified_name: "load",
            owner_name: nil,
            kind: Chiasmus::Graph::SymbolKind::Method,
            file: "src/service_config.cr",
            line: 4
          ),
        ],
        exports: [
          Chiasmus::Graph::IR::ExportEdge.new("src/demo_config.cr", "load"),
          Chiasmus::Graph::IR::ExportEdge.new("src/service_config.cr", "load"),
        ],
        contains: [
          Chiasmus::Graph::IR::ContainsEdge.new("Demo", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
          Chiasmus::Graph::IR::ContainsEdge.new("Service", "Config"),
          Chiasmus::Graph::IR::ContainsEdge.new("Config", "load"),
        ]
      )

      normalized = Chiasmus::Graph::IR.normalize(graph)

      normalized.exports.should eq([
        Chiasmus::Graph::IR::ExportEdge.new("src/demo_config.cr", "Demo.Config.load"),
        Chiasmus::Graph::IR::ExportEdge.new("src/service_config.cr", "Service.Config.load"),
      ])
    end
  end
end
