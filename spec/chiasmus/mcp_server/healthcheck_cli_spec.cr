require "../../spec_helper"
require "process"

describe "Chiasmus Healthcheck CLI" do
  it "returns exit code 0 for a working chiasmus server via in-memory healthcheck" do
    cmd, args = chiasmus_cli_command(["--healthcheck"])

    output = IO::Memory.new
    error = IO::Memory.new

    status = Process.run(cmd, args, env: chiasmus_cli_env, output: output, error: error)

    status.exit_code.should eq(0)
    output.to_s.should contain("healthcheck OK")
    output.to_s.should contain("version:")
    output.to_s.should contain("tools:")
    output.to_s.should_not contain("FAILED")
  end

  it "healthcheck completes successfully via in-memory transport when launched with crystal run" do
    cmd, args = chiasmus_cli_command(["--healthcheck"])

    output = IO::Memory.new
    error = IO::Memory.new

    elapsed = Time.measure do
      Process.run(cmd, args, env: chiasmus_cli_env, output: output, error: error)
    end

    output.to_s.should contain("healthcheck OK")
    # crystal run includes compile + launch overhead, so this is a coarse
    # hang detector rather than a raw healthcheck latency assertion.
    elapsed.should be < 30.seconds
  end

  it "does NOT depend on an external chiasmus binary for healthcheck" do
    cmd, args = chiasmus_cli_command(["--healthcheck"])
    output = IO::Memory.new
    error = IO::Memory.new

    with_env({"CHIASMUS_BIN" => "/definitely/missing/chiasmus"}) do
      status = Process.run(cmd, args, env: chiasmus_cli_env, output: output, error: error)

      status.exit_code.should eq(0)
    end

    output.to_s.should contain("healthcheck OK")
  end
end
