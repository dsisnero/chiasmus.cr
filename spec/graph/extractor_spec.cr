require "../spec_helper"

private def load_go_language
  Chiasmus::Discovery.register_grammar_directory(
    File.expand_path("../../vendor/grammars", __DIR__)
  )
  Chiasmus::Discovery::GrammarLoader.load_language("go")
end

describe Chiasmus::Graph::Walkers do
  describe ".walk_go" do
    it "extracts function declarations" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\nfunc hello() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      names = defines.map(&.name)
      names.should contain("hello")
    end

    it "extracts methods with receiver type" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\ntype Server struct {}\nfunc (s *Server) Start() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      names = defines.map(&.name)
      names.should contain("Start")
      names.should contain("Server")
    end

    it "extracts call relationships" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\nfunc main() { helper() }\nfunc helper() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      calls.size.should be > 0
      calls.map { |c| "#{c.caller}->#{c.callee}" }.should contain("main->helper")
    end

    it "extracts struct definitions" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\ntype Server struct { Name string }\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      classes = defines.select { |d| d.kind.class? }
      classes.map(&.name).should contain("Server")
    end

    it "extracts import declarations" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\nimport \"fmt\"\nfunc main() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      imports.map(&.name).should contain("fmt")
    end

    it "exports uppercase symbols only" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\nfunc PublicFunc() {}\nfunc privateFunc() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      exports.map(&.name).should contain("PublicFunc")
      exports.map(&.name).should_not contain("privateFunc")
    end

    it "deduplicates call edges" do
      lang = load_go_language
      pending "go grammar not available" unless lang
      parser = TreeSitter::Parser.new(language: lang)
      source = "package main\nfunc f() { g(); g() }\nfunc g() {}\n"
      tree = parser.parse(nil, source)

      defines = [] of Chiasmus::Graph::DefinesFact
      calls = [] of Chiasmus::Graph::CallsFact
      imports = [] of Chiasmus::Graph::ImportsFact
      exports = [] of Chiasmus::Graph::ExportsFact
      contains = [] of Chiasmus::Graph::ContainsFact
      call_set = Set(String).new

      Chiasmus::Graph::Walkers.walk_go(
        tree.root_node, source, "main.go",
        defines, calls, imports, exports, contains, call_set
      )

      calls.size.should eq(1)
    end
  end
end
