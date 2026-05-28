require "../../spec_helper"
require "json"

describe Chiasmus::Search::CodeDocument do
  it "round-trips through JSON" do
    doc = Chiasmus::Search::CodeDocument.new(
      id: "src/app.go#Server.ServeHTTP#42",
      name: "Server.ServeHTTP",
      kind: "method",
      language: "go",
      file: "src/app.go",
      line: 42,
      signature: "func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request)",
      leading_doc: "ServeHTTP handles incoming requests",
      text: "func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { ... }",
    )

    json = doc.to_json
    restored = Chiasmus::Search::CodeDocument.from_json(json)

    restored.id.should eq(doc.id)
    restored.name.should eq(doc.name)
    restored.kind.should eq(doc.kind)
    restored.language.should eq(doc.language)
    restored.file.should eq(doc.file)
    restored.line.should eq(doc.line)
    restored.signature.should eq(doc.signature)
    restored.leading_doc.should eq(doc.leading_doc)
    restored.text.should eq(doc.text)
  end

  it "handles nil optional fields through JSON" do
    doc = Chiasmus::Search::CodeDocument.new(
      id: "src/lib.rs#parse#10",
      name: "parse",
      kind: "function",
      language: "rust",
      file: "src/lib.rs",
      line: 10,
      signature: nil,
      leading_doc: nil,
      text: "fn parse(input: &str) -> Result<Ast> { ... }",
    )

    json = doc.to_json
    restored = Chiasmus::Search::CodeDocument.from_json(json)

    restored.signature.should be_nil
    restored.leading_doc.should be_nil
  end
end

describe Chiasmus::Search::CodeIndexConfig do
  it "defaults indexed_kinds to function + method" do
    config = Chiasmus::Search::CodeIndexConfig.new
    config.indexed_kinds.should contain("function")
    config.indexed_kinds.should contain("method")
    config.indexed_kinds.size.should eq(2)
  end

  it "defaults max_text_len to 2000" do
    config = Chiasmus::Search::CodeIndexConfig.new
    config.max_text_len.should eq(2000)
  end

  it "defaults snippet_lines to 6" do
    config = Chiasmus::Search::CodeIndexConfig.new
    config.snippet_lines.should eq(6)
  end

  it "accepts custom indexed_kinds" do
    config = Chiasmus::Search::CodeIndexConfig.new(
      indexed_kinds: ["class", "interface", "function", "method"].to_set,
    )
    config.indexed_kinds.should contain("class")
    config.indexed_kinds.should contain("interface")
    config.indexed_kinds.should contain("function")
    config.indexed_kinds.should contain("method")
    config.indexed_kinds.size.should eq(4)
  end

  it "rejects items whose kind is not in indexed_kinds" do
    config = Chiasmus::Search::CodeIndexConfig.new
    config.includes_kind?("function").should be_true
    config.includes_kind?("method").should be_true
    config.includes_kind?("class").should be_false
    config.includes_kind?("test").should be_false
  end

  it "has sensible Go defaults (class + interface included)" do
    config = Chiasmus::Search::CodeIndexConfig.defaults_for("go")
    config.includes_kind?("function").should be_true
    config.includes_kind?("method").should be_true
    config.includes_kind?("class").should be_true
    config.includes_kind?("interface").should be_true
  end

  it "has sensible TypeScript defaults" do
    config = Chiasmus::Search::CodeIndexConfig.defaults_for("typescript")
    config.includes_kind?("function").should be_true
    config.includes_kind?("method").should be_true
    config.includes_kind?("class").should be_true
    config.includes_kind?("interface").should be_true
    config.includes_kind?("type").should be_true
  end

  it "falls back to function+method for unknown languages" do
    config = Chiasmus::Search::CodeIndexConfig.defaults_for("brainfuck")
    config.includes_kind?("function").should be_true
    config.includes_kind?("method").should be_true
    config.includes_kind?("class").should be_false
  end
end

describe Chiasmus::Search::CodeIndex do
  describe ".for_language" do
    it "returns a Builder for the given language" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")
      builder.language.should eq("go")
    end
  end

  describe "Builder" do
    it "defaults config from language defaults" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")
      config = builder.config
      config.includes_kind?("class").should be_true
      config.includes_kind?("function").should be_true
    end

    it "accepts custom config" do
      custom = Chiasmus::Search::CodeIndexConfig.new(indexed_kinds: ["function"].to_set)
      builder = Chiasmus::Search::CodeIndex.for_language("go").with_config(custom)
      builder.config.includes_kind?("class").should be_false
      builder.config.includes_kind?("function").should be_true
    end

    it "filters items by indexed_kinds" do
      builder = Chiasmus::Search::CodeIndex.for_language("go").with_config(
        Chiasmus::Search::CodeIndexConfig.new(indexed_kinds: ["function"].to_set),
      )

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/pkg.go::function::DoStuff",
          kind: "function", scope: "source", name: "DoStuff", file: "src/pkg.go",
        ),
        Chiasmus::Discovery::Item.new(
          id: "src/pkg.go::class::Server",
          kind: "class", scope: "source", name: "Server", file: "src/pkg.go",
        ),
        Chiasmus::Discovery::Item.new(
          id: "src/pkg_test.go::test::TestServer",
          kind: "test", scope: "test", name: "TestServer", file: "src/pkg_test.go",
        ),
      ]

      sources = {
        "src/pkg.go"      => "package pkg\n\nfunc DoStuff() {}\n\ntype Server struct{}",
        "src/pkg_test.go" => "package pkg_test\n\nfunc TestServer(t *testing.T) {}",
      }

      builder = builder.from_items(items, sources)
      builder.documents.size.should eq(1)
      builder.documents[0].kind.should eq("function")
      builder.documents[0].name.should eq("DoStuff")
    end

    it "builds CodeDocuments with correct fields from items" do
      builder = Chiasmus::Search::CodeIndex.for_language("typescript")

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/utils.ts::function::parseJSON",
          kind: "function", scope: "source", name: "parseJSON", file: "src/utils.ts",
        ),
      ]

      source_lines = [
        "// Parse JSON safely",
        "export function parseJSON(input: string): unknown {",
        "  try { return JSON.parse(input) }",
        "  catch { return null }",
        "}",
      ]
      sources = {"src/utils.ts" => source_lines.join("\n")}

      builder = builder.from_items(items, sources)
      builder.documents.size.should eq(1)
      doc = builder.documents[0]
      doc.name.should eq("parseJSON")
      doc.kind.should eq("function")
      doc.language.should eq("typescript")
      doc.file.should eq("src/utils.ts")
      doc.line.should eq(2)
      doc.id.should eq("src/utils.ts::function::parseJSON")
    end

    it "extracts snippet around the symbol line from source" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")
      config = Chiasmus::Search::CodeIndexConfig.new(
        indexed_kinds: ["function"].to_set,
        snippet_lines: 4,
      )
      builder = builder.with_config(config)

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/app.go::function::Respond", kind: "function",
          scope: "source", name: "Respond", file: "src/app.go",
        ),
      ]

      sources = {
        "src/app.go" => [
          "package app",
          "",
          "func Respond(w http.ResponseWriter) {",
          "  log.Println(\"responding\")",
          "  w.WriteHeader(200)",
          "}",
        ].join("\n"),
      }

      builder = builder.from_items(items, sources)
      doc = builder.documents[0]

      doc.text.should contain("Respond")
      doc.text.should contain("log.Println")
    end

    it "handles missing source content gracefully" do
      builder = Chiasmus::Search::CodeIndex.for_language("python")

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/missing.py::function::nope", kind: "function",
          scope: "source", name: "nope", file: "src/missing.py",
        ),
      ]

      sources = {} of String => String
      builder = builder.from_items(items, sources)
      doc = builder.documents[0]
      doc.text.should contain("nope") # at minimum includes the name
    end

    it "rejects items with empty id" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")

      items = [
        Chiasmus::Discovery::Item.new(
          id: "", kind: "function", scope: "source", name: "bad", file: "src/bad.go",
        ),
      ]

      sources = {"src/bad.go" => "func bad() {}"}
      builder = builder.from_items(items, sources)
      builder.documents.size.should eq(0)
    end

    it "builds a CodeIndex after embedding" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/pkg.go::function::Hello", kind: "function",
          scope: "source", name: "Hello", file: "src/pkg.go",
        ),
      ]

      sources = {"src/pkg.go" => "package pkg\n\nfunc Hello() string { return \"hello\" }"}
      builder = builder.from_items(items, sources)
      builder.documents.size.should eq(1)

      index = builder.build
      index.should be_a(Chiasmus::Search::CodeIndex)
      index.count.should eq(1)
    end
  end

  describe "#count" do
    it "returns 0 for empty index" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")
      builder.build.count.should eq(0)
    end
  end

  describe "#language" do
    it "returns the configured language" do
      builder = Chiasmus::Search::CodeIndex.for_language("ruby")
      index = builder.build
      index.language.should eq("ruby")
    end
  end
end

describe Chiasmus::Search::CodeIndex do
  describe "#search" do
    it "returns empty for an empty index" do
      index = Chiasmus::Search::CodeIndex.for_language("go").build
      results = index.search("query")
      results.size.should eq(0)
    end

    it "finds documents by keyword match" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/a.go::function::Alpha", kind: "function",
          scope: "source", name: "Alpha", file: "src/a.go",
        ),
        Chiasmus::Discovery::Item.new(
          id: "src/b.go::function::Beta", kind: "function",
          scope: "source", name: "Beta", file: "src/b.go",
        ),
      ]

      sources = {
        "src/a.go" => "package main\n\nfunc Alpha() { doDatabase() }",
        "src/b.go" => "package main\n\nfunc Beta() { writeFile() }",
      }

      index = builder.from_items(items, sources).build
      results = index.search("database")
      results.size.should eq(1)
      results[0].document.name.should eq("Alpha")
    end

    it "returns top_k results" do
      builder = Chiasmus::Search::CodeIndex.for_language("go")

      items = (1..5).map do |i|
        name = "Func#{i}"
        Chiasmus::Discovery::Item.new(
          id: "src/f#{i}.go::function::#{name}", kind: "function",
          scope: "source", name: name, file: "src/f#{i}.go",
        )
      end

      sources = (1..5).to_h do |i|
        {"src/f#{i}.go", "package main\n\nfunc Func#{i}() { doThing() }"}
      end

      index = builder.from_items(items, sources).build
      results = index.search("thing", top_k: 3)
      results.size.should eq(3)
    end

    it "filters by language" do
      go_builder = Chiasmus::Search::CodeIndex.for_language("go")
      go_items = [
        Chiasmus::Discovery::Item.new(
          id: "src/a.go::function::Alpha", kind: "function",
          scope: "source", name: "Alpha", file: "src/a.go",
        ),
      ]
      go_sources = {"src/a.go" => "package main\n\nfunc Alpha() { doThing() }"}
      go_index = go_builder.from_items(go_items, go_sources).build

      ts_builder = Chiasmus::Search::CodeIndex.for_language("typescript")
      ts_items = [
        Chiasmus::Discovery::Item.new(
          id: "src/b.ts::function::Beta", kind: "function",
          scope: "source", name: "Beta", file: "src/b.ts",
        ),
      ]
      ts_sources = {"src/b.ts" => "export function Beta() { doThing() }"}
      ts_index = ts_builder.from_items(ts_items, ts_sources).build

      # Multi-index search
      all_results = go_index.search("thing") + ts_index.search("thing")
      all_results.size.should eq(2)

      go_results = all_results.select { |r| r.document.language == "go" }
      go_results.size.should eq(1)
      go_results[0].document.name.should eq("Alpha")
    end

    it "filters by kind" do
      builder = Chiasmus::Search::CodeIndex.for_language("typescript").with_config(
        Chiasmus::Search::CodeIndexConfig.new(
          indexed_kinds: ["function", "class"].to_set,
        ),
      )

      items = [
        Chiasmus::Discovery::Item.new(
          id: "src/a.ts::function::doStuff", kind: "function",
          scope: "source", name: "doStuff", file: "src/a.ts",
        ),
        Chiasmus::Discovery::Item.new(
          id: "src/a.ts::class::Service", kind: "class",
          scope: "source", name: "Service", file: "src/a.ts",
        ),
      ]

      sources = {
        "src/a.ts" => "export function doStuff() { return new Service() }\n\nexport class Service { handle() {} }",
      }

      index = builder.from_items(items, sources).build
      results = index.search("handle")
      results.size.should eq(2) # both match "handle" via "Service"

      # user can filter client-side by kind
      class_results = results.select { |r| r.document.kind == "class" }
      class_results.size.should eq(1)
      class_results[0].document.kind.should eq("class")
      class_results[0].document.name.should eq("Service")
    end
  end
end
