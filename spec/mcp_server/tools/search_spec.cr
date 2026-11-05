require "../../spec_helper"
require "json"
require "file_utils"
require "tree-sitter-manager"

class Chiasmus::MCPServer::Tools::SearchTool
  def read_search_files_for_test(files : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String)
    read_search_files(files, max_concurrent, &reader)
  end

  def directory_search_files_for_test(directory : String, patterns : Array(String)?)
    directory_search_files(directory, patterns)
  end
end

private def make_item(id, kind, name, file, scope = "source", span = nil)
  Chiasmus::Discovery::Item.new(
    id: id, kind: kind, scope: scope, name: name, file: file,
    span: span,
  )
end

describe Chiasmus::MCPServer::Tools::SearchTool do
  describe "search hit serialization" do
    it "includes line_end when present" do
      hit = Chiasmus::MCPServer::Types::SearchHitJSON.new(
        name: "call",
        file: "src/app.cr",
        line: 10,
        line_end: 13,
        score: 0.91
      )

      payload = JSON.parse(hit.to_json)
      payload["line"].as_i.should eq(10)
      payload["line_end"].as_i.should eq(13)
    end
  end

  describe "file preparation" do
    it "uses supported source discovery, relative include globs, and stable ordering for directory input" do
      root = File.join(Dir.tempdir, "search-directory-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(File.join(root, "src", "nested"))
      Dir.mkdir_p(File.join(root, "docs"))
      expected = File.join(root, "src", "nested", "a.cr")
      File.write(expected, "def found; end\n")
      File.write(File.join(root, "docs", "note.md"), "ignored")
      File.write(File.join(root, "src", "b.cr"), "def other; end\n")

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        selected = tool.directory_search_files_for_test(root, ["src/**/*.cr"] of String)
        selected.should eq([File.join(root, "src", "b.cr"), expected].map { |path| File.realpath(path) })
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "rejects source symlinks that resolve outside the directory" do
      root = File.join(Dir.tempdir, "search-symlink-#{Random::Secure.hex(8)}")
      outside = File.join(Dir.tempdir, "search-outside-#{Random::Secure.hex(8)}.cr")
      Dir.mkdir_p(root)
      File.write(outside, "def secret; end\n")
      link = File.join(root, "escape.cr")
      File.symlink(outside, link)
      begin
        Process.run("git", ["init", "-q", root]).success?.should be_true
        Process.run("git", ["-C", root, "add", "escape.cr"]).success?.should be_true
        Chiasmus::Index::FileDiscovery.paths(root).should contain(link)
        selected = Chiasmus::MCPServer::Tools::SearchTool.new.directory_search_files_for_test(root, nil)
        selected.should be_empty
      ensure
        FileUtils.rm_rf(root)
        File.delete(outside) if File.exists?(outside)
      end
    end

    it "rejects a directory corpus over the file-count bound" do
      root = File.join(Dir.tempdir, "search-limit-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(root)
      501.times do |index|
        File.write(File.join(root, "f#{index}.cr"), "")
      end
      begin
        expect_raises(ArgumentError, /exceeds 500 files/) do
          Chiasmus::MCPServer::Tools::SearchTool.new.directory_search_files_for_test(root, nil)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "rejects a directory corpus over the total-byte bound" do
      root = File.join(Dir.tempdir, "search-byte-limit-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(root)
      payload = "x" * Chiasmus::MCPServer::Tools::SearchTool::MAX_FILE_SIZE
      53.times do |index|
        File.write(File.join(root, "f#{index}.cr"), payload)
      end
      begin
        expect_raises(ArgumentError, /exceeds .* bytes/) do
          Chiasmus::MCPServer::Tools::SearchTool.new.directory_search_files_for_test(root, nil)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "reports searched file count for an empty directory corpus" do
      root = File.join(Dir.tempdir, "search-empty-dir-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(root)
      File.write(File.join(root, "empty.cr"), "# no definitions\n")
      begin
        response = Chiasmus::MCPServer::Tools::SearchTool.new.invoke({
          "query"     => JSON::Any.new("find function"),
          "directory" => JSON::Any.new(root),
        })
        response.should be_a(Chiasmus::MCPServer::Types::SearchResponse)
        response.as(Chiasmus::MCPServer::Types::SearchResponse).searched_files.should eq(1)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "returns a typed warning-bearing error when every requested file is unreadable" do
      missing = File.join(Dir.tempdir, "chiasmus-search-missing-#{Random::Secure.hex(8)}.cr")
      tool = Chiasmus::MCPServer::Tools::SearchTool.new

      response = tool.invoke({
        "query" => JSON::Any.new("find function"),
        "files" => JSON.parse([missing].to_json),
      })

      response.should be_a(Chiasmus::MCPServer::Types::SearchErrorResponse)
      error = response.as(Chiasmus::MCPServer::Types::SearchErrorResponse)
      error.status.should eq("error")
      error.error.should eq("No readable files in `files`.")
      error.warnings.size.should eq(1)
      error.warnings.first.should contain("read failed: #{missing}")
    end

    it "preserves a successful empty corpus without requiring an embedding provider" do
      tmpdir = File.join(Dir.tempdir, "search-tool-empty-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      path = File.join(tmpdir, "empty.cr")
      File.write(path, "# no definitions\n")

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        response = tool.invoke({
          "query" => JSON::Any.new("find function"),
          "files" => JSON.parse([path].to_json),
        })

        response.should be_a(Chiasmus::MCPServer::Types::SearchResponse)
        search = response.as(Chiasmus::MCPServer::Types::SearchResponse)
        search.status.should eq("success")
        search.hits.should be_empty
        search.warnings.should be_nil
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end

    it "reads files with bounded concurrency" do
      tmpdir = File.join(Dir.tempdir, "search-tool-files-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)

      paths = 6.times.map do |i|
        path = File.join(tmpdir, "f#{i}.ts")
        File.write(path, "export function f#{i}() {}")
        path
      end.to_a

      active = 0
      peak = 0
      mutex = Mutex.new

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        files, warnings = tool.read_search_files_for_test(paths, 2) do |path|
          mutex.synchronize do
            active += 1
            peak = {peak, active}.max
          end

          sleep 20.milliseconds
          File.read(path)
        ensure
          mutex.synchronize do
            active -= 1
          end
        end

        files.size.should eq(6)
        warnings.should be_empty
        peak.should be <= 2
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe "graph extraction boundary" do
    it "uses async graph extraction before continuing to embedding resolution" do
      tmpdir = File.join(Dir.tempdir, "search-tool-async-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      path = File.join(tmpdir, "f.ts")
      File.write(path, "export function f() {}")
      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)
      result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

      Chiasmus::Graph::Extractor.set_before_async_result_send_hook_for_test do
        entered.send(true)
        release.receive?
      end

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        spawn do
          with_env({
            "CHIASMUS_EMBED_PROVIDER" => "deepseek",
            "DEEPSEEK_API_KEY"        => nil,
            "OPENAI_API_KEY"          => nil,
          }) do
            result_chan.send(tool.invoke({
              "query" => JSON::Any.new("find function"),
              "files" => JSON.parse([path].to_json),
            }))
          end
        end

        TreeSitterManager::Timeout.with_timeout_async(250, entered).should eq(true)

        select
        when result_chan.receive?
          fail("expected SearchTool to remain blocked on async extraction result")
        else
        end

        release.send(true)
        result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
        result.should_not be_nil
        search_result = result || raise "expected search tool result"
        search_result.status.should eq("error")
      ensure
        Chiasmus::Graph::Extractor.clear_before_async_result_send_hook_for_test
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe "input schema" do
    it "accepts a directory with optional include globs instead of files" do
      root = File.join(Dir.tempdir, "search-schema-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(root)
      valid = {
        "query"     => JSON::Any.new("find function"),
        "directory" => JSON::Any.new(root),
        "include"   => JSON.parse(["src/**/*.cr"].to_json),
      }
      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments(valid).should be_nil

      begin
        schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
        schema.properties.has_key?("directory").should be_true
        schema.properties.has_key?("include").should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "requires exactly one of files and directory, and scopes include to directory" do
      query = JSON::Any.new("find function")
      files = JSON.parse(["/project/a.cr"].to_json)
      dir = JSON::Any.new("/project")

      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments({"query" => query}).should_not be_nil
      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments({"query" => query, "files" => files, "directory" => dir}).should_not be_nil
      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments({"query" => query, "files" => files, "include" => JSON.parse(["*.cr"].to_json)}).should_not be_nil
      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments({"query" => query, "directory" => JSON::Any.new("relative")}).should_not be_nil
      Chiasmus::MCPServer::Tools::SearchTool.validate_arguments({"query" => query, "files" => JSON.parse(["relative.cr"].to_json)}).should be_nil
    end

    it "requires query and accepts either files or directory" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("query").should be_true
      schema.properties.has_key?("files").should be_true
      req = schema.required
      req.should_not be_nil
      if r = req
        r.includes?("query").should be_true
        r.includes?("files").should be_false
      end
    end

    it "includes languages filter param" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("languages").should be_true
      schema.properties["languages"]["type"].as_s.should eq("array")
    end

    it "includes kinds filter param" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("kinds").should be_true
      schema.properties["kinds"]["type"].as_s.should eq("array")
    end
  end
end
