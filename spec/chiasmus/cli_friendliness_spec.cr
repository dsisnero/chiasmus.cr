require "../spec_helper"

describe "chiasmus CLI friendliness" do
  it "prints help when --help is passed" do
    output = IO::Memory.new
    Process.run("./bin/chiasmus", ["--help"], output: output, error: output)
    output.to_s.should_not be_empty
    output.to_s.should contain("Usage")
    output.to_s.should contain("Chiasmus MCP server")
    output.to_s.should contain("Options")
  end

  it "prints version with --version" do
    output = IO::Memory.new
    Process.run("./bin/chiasmus", ["--version"], output: output, error: output)
    output.to_s.should contain("chiasmus v")
    output.to_s.should contain("0.")
  end

  it "prints startup message to stderr when starting server with no args" do
    proc = Process.new(
      "./bin/chiasmus",
      output: Process::Redirect::Pipe,
      input: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )
    ch = Channel(String?).new
    spawn { ch.send(proc.error.gets) }
    line1 = nil
    select
    when l = ch.receive; line1 = l
    when timeout(3.seconds)
    end
    proc.terminate rescue nil

    (line1 || "").should_not be_empty
    (line1 || "").should contain("Starting")
  end

  it "prints startup banner with version" do
    proc = Process.new(
      "./bin/chiasmus",
      output: Process::Redirect::Pipe,
      input: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )
    ch = Channel(String?).new
    spawn do
      ch.send(proc.error.gets) rescue nil
      ch.send(proc.error.gets) rescue nil
    end
    parts = [] of String
    2.times do
      select
      when l = ch.receive; parts << (l || "")
      when timeout(3.seconds); break
      end
    end
    proc.terminate rescue nil

    banner = parts.join
    banner.should contain(Chiasmus::VERSION)
  end
end
