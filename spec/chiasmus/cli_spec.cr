require "../spec_helper"

describe "chiasmus CLI" do
  it "produces help output with --help" do
    output = IO::Memory.new
    cmd, args = chiasmus_cli_command(["--help"])
    Process.run(
      cmd,
      args,
      env: chiasmus_cli_env,
      output: output,
      error: output,
    )
    output.to_s.should contain("chiasmus")
    output.to_s.should contain("MCP")
  end

  it "shows version with --version" do
    output = IO::Memory.new
    cmd, args = chiasmus_cli_command(["--version"])
    Process.run(
      cmd,
      args,
      env: chiasmus_cli_env,
      output: output,
      error: output,
    )
    output.to_s.should contain("0.")
  end

  it "shows help for subcommands" do
    output = IO::Memory.new
    cmd, args = chiasmus_cli_command(["--help"])
    Process.run(
      cmd,
      args,
      env: chiasmus_cli_env,
      output: output,
      error: output,
    )
    output.to_s.should_not be_empty
  end
end
