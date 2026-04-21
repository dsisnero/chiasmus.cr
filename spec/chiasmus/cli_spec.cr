require "spec"
require "file_utils"
require "process"
require "../../src/chiasmus/cli"

module ChiasmusCliSpecHelpers
  extend self

  def binary_path : String
    File.join(Dir.tempdir, "chiasmus-grammar-spec-#{Process.pid}")
  end

  def build_binary : Nil
    status = Process.run("crystal", ["build", "src/chiasmus_grammar.cr", "-o", binary_path],
      output: Process::Redirect::Close,
      error: Process::Redirect::Close)
    raise "failed to build chiasmus-grammar test binary" unless status.success?
  end

  def cleanup_binary : Nil
    File.delete(binary_path) if File.exists?(binary_path)
  end

  def run_cli(args : Array(String), env : Hash(String, String) = {} of String => String) : {Process::Status, String, String}
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary_path, args, env: env, output: output, error: error)
    {status, output.to_s, error.to_s}
  end
end

describe Chiasmus::CLI do
  before_all do
    ChiasmusCliSpecHelpers.build_binary
  end

  after_all do
    ChiasmusCliSpecHelpers.cleanup_binary
  end

  describe "command parsing" do
    it "shows help for unknown command" do
      status, output, error = ChiasmusCliSpecHelpers.run_cli(["definitely-unknown"])

      status.success?.should be_false
      error.should eq ""
      output.should contain("Unknown command: definitely-unknown")
      output.should contain("Chiasmus Grammar Manager")
    end
  end

  describe "show_status" do
    it "shows grammars available from the cache directory" do
      temp_cache_root = File.join(Dir.tempdir, "chiasmus-cli-cache-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(temp_cache_root)

      begin
        status, output, error = ChiasmusCliSpecHelpers.run_cli(
          ["status"],
          {"XDG_CACHE_HOME" => temp_cache_root}
        )

        status.success?.should be_true
        error.should eq ""
        output.should contain("✓")
      ensure
        FileUtils.rm_rf(temp_cache_root)
      end
    end
  end
end
