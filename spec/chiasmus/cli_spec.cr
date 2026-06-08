require "../spec_helper"

describe "chiasmus CLI" do
  it "produces help output with --help" do
    output = IO::Memory.new
    Process.run(
      "./bin/chiasmus",
      ["--help"],
      output: output,
      error: output,
    )
    output.to_s.should contain("chiasmus")
    output.to_s.should contain("MCP")
  end

  it "shows version with --version" do
    output = IO::Memory.new
    Process.run(
      "./bin/chiasmus",
      ["--version"],
      output: output,
      error: output,
    )
    output.to_s.should contain("0.")
  end

  it "shows help for subcommands" do
    output = IO::Memory.new
    Process.run(
      "./bin/chiasmus",
      ["--help"],
      output: output,
      error: output,
    )
    output.to_s.should_not be_empty
  end
end
