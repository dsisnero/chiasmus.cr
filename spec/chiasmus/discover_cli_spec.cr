require "spec"
require "../../src/chiasmus/discover_cli"
require "../../src/chiasmus/facts_cli"
require "tree-sitter-manager"
require "file_utils"

describe Chiasmus::DiscoverCLI do
  it "emits stable native Go declaration IDs alongside auxiliary kinds" do
    dir = File.join(Dir.tempdir, "discover-cli-go-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    cache_dir = File.join(dir, "cache")
    Dir.mkdir_p(source_dir)

    begin
      File.write(File.join(source_dir, "server.go"), <<-GO)
        package sample

        import "io"

        const DefaultPort = 8080
        const (
            MinPort = 1
            MaxPort = 65535
        )

        type Port int
        type Listener interface { Start(port Port) bool }
        type Server struct { Port Port }
        type PortAlias = Port
        type PortPointer *Port
        type (
            Buffer []byte
            Handler func(Port) bool
            Index[T comparable] map[T]Port
            Reader io.Reader
            ServerAlias = struct { Port Port }
            ListenerAlias = interface { Start(port Port) bool }
        )

        func Ready(port Port) bool { return port > 0 }
        func (server *Server) Start(port Port) bool {
            _ = Server{Port: port}
            return Ready(port)
        }
        GO
      File.write(File.join(source_dir, "server_test.go"), <<-GO)
        package sample

        import "testing"

        func TestReady(t *testing.T) { t.Log(Ready(DefaultPort)) }
        GO

      args = ["--language", "go", "--dir", dir, "--parser", "tree-sitter"]
      output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(args, output: output).should eq(0)
      rows = output.to_s.lines.reject(&.starts_with?('#')).map(&.split('\t'))
      rows.map(&.[4]).uniq!.should eq(["parser=tree-sitter"])

      declaration_kinds = %w[function class interface method const test type]
      declarations, auxiliary = rows.map { |row| {row[0], row[1]} }
        .partition { |(_id, kind)| declaration_kinds.includes?(kind) }
      declarations.sort!.should eq([
        {"src/server.go::class::Server", "class"},
        {"src/server.go::const::DefaultPort", "const"},
        {"src/server.go::const::MaxPort", "const"},
        {"src/server.go::const::MinPort", "const"},
        {"src/server.go::function::Ready", "function"},
        {"src/server.go::interface::Listener", "interface"},
        {"src/server.go::method::Server.Start", "method"},
        {"src/server.go::type::Buffer", "type"},
        {"src/server.go::type::Handler", "type"},
        {"src/server.go::type::Index", "type"},
        {"src/server.go::type::ListenerAlias", "type"},
        {"src/server.go::type::Port", "type"},
        {"src/server.go::type::PortAlias", "type"},
        {"src/server.go::type::PortPointer", "type"},
        {"src/server.go::type::Reader", "type"},
        {"src/server.go::type::ServerAlias", "type"},
        {"src/server_test.go::function::TestReady", "function"},
        {"src/server_test.go::test::TestReady", "test"},
      ])
      auxiliary.should contain({"src/server.go::definition.type::Port", "definition.type"})
      auxiliary.should contain({"src/server.go::definition.function::Ready", "definition.function"})
      auxiliary.should contain({"src/server.go::definition.method::Server.Start", "definition.method"})
      auxiliary.should contain({"src/server.go::field::Port", "field"})
      auxiliary.should contain({"src/server.go::package::sample", "package"})
      auxiliary.should contain({"src/server.go::params::Server.Start", "params"})
      auxiliary.should contain({"src/server.go::reference.call::Ready", "reference.call"})
      auxiliary.should contain({"src/server.go::reference.class::Server", "reference.class"})
      auxiliary.should contain({"src/server.go::return_type::Ready", "return_type"})

      trailing_root_args = ["--language", "go", "--dir", "#{dir}#{File::SEPARATOR}", "--parser", "tree-sitter"]
      trailing_root_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(trailing_root_args, output: trailing_root_output).should eq(0)
      trailing_root_output.to_s.lines.sort!.should eq(output.to_s.lines.sort!)

      [args, trailing_root_args].each do |cached_args|
        cached_output = IO::Memory.new
        Chiasmus::DiscoverCLI.run(cached_args + ["--cache-dir", cache_dir], output: cached_output).should eq(0)
        cached_output.to_s.lines.sort!.should eq(output.to_s.lines.sort!)
        Chiasmus::Graph::GraphCache.flush_async_writes
        Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      end
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "shares cached extraction with facts and sees edited declarations" do
    dir = File.join(Dir.tempdir, "discover-cli-shared-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    cache_dir = File.join(dir, "cache")
    Dir.mkdir_p(source_dir)
    source_path = File.join(source_dir, "Greeter.java")
    File.write(source_path, "class Greeter { void greet() {} }")

    begin
      facts_output = IO::Memory.new
      Chiasmus::FactsCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: facts_output).should eq(0)

      cached_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: cached_output).should eq(0)
      uncached_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir], output: uncached_output).should eq(0)
      cached_output.to_s.should eq(uncached_output.to_s)

      File.write(source_path, "class Greeter { void greet() {} void wave() {} }")
      edited_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: edited_output).should eq(0)
      edited_output.to_s.should contain("method::wave")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "reads source files with bounded concurrency during CLI scan" do
    dir = File.join(Dir.tempdir, "discover-cli-scan-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      {
        "a.ts" => "export function a() {}\n",
        "b.ts" => "export function b() {}\n",
        "c.ts" => "export function c() {}\n",
      }.each do |name, content|
        File.write(File.join(dir, name), content)
      end

      entered = Channel(String).new(3)
      release = Channel(Bool).new(3)
      result_channel = Channel(Array(Tuple(String, String))).new(1)

      begin
        Chiasmus::DiscoverCLI.scan_max_concurrent_for_test = 2
        Chiasmus::DiscoverCLI.set_before_scan_file_read_hook_for_test do |path|
          entered.send(File.basename(path))
          release.receive
        end

        spawn do
          result_channel.send(Chiasmus::DiscoverCLI.scan_files_for_test("typescript", dir))
        end

        first = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        second = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        first.should_not be_nil
        second.should_not be_nil

        select
        when entered.receive
          fail("expected discover CLI scan to honor the bounded read limit")
        when timeout 50.milliseconds
        end

        release.send(true)
        third = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        third.should_not be_nil
        2.times { release.send(true) }

        result = TreeSitterManager::Timeout.with_timeout_async(1_000, result_channel)
        result.should_not be_nil
        entries = result || raise "expected discovered entries"
        entries.map(&.[0]).to_set.should eq(Set{"a.ts", "b.ts", "c.ts"})
      ensure
        Chiasmus::DiscoverCLI.clear_before_scan_file_read_hook_for_test
        Chiasmus::DiscoverCLI.clear_scan_max_concurrent_for_test
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
