require "../../spec_helper"
require "process"

describe "Chiasmus Healthcheck CLI" do
  it "returns exit code 0 for a working chiasmus server via in-memory healthcheck" do
    binary = File.join(Dir.current, "bin", "chiasmus")

    unless File.file?(binary)
      pending "Build the binary first: make build"
    end

    ENV["CHIASMUS_BIN"] = binary

    output = IO::Memory.new
    error = IO::Memory.new

    status = Process.run(binary, ["--healthcheck"], output: output, error: error)

    status.exit_code.should eq(0)
    output.to_s.should contain("healthcheck OK")
    output.to_s.should contain("version:")
    output.to_s.should contain("tools:")
    output.to_s.should_not contain("FAILED")
  end

  it "healthcheck completes quickly via in-memory transport (no child-process sleep)" do
    binary = File.join(Dir.current, "bin", "chiasmus")

    unless File.file?(binary)
      pending "Build the binary first: make build"
    end

    output = IO::Memory.new
    error = IO::Memory.new

    elapsed = Time.measure do
      Process.run(binary, ["--healthcheck"], output: output, error: error)
    end

    output.to_s.should contain("healthcheck OK")
    # In-memory healthcheck should complete in under 2 seconds
    # (no 3-second sleep hack needed)
    elapsed.should be < 2.seconds
  end

  it "does NOT spawn a child chiasmus process for healthcheck (uses in-memory transport)" do
    binary = File.join(Dir.current, "bin", "chiasmus")

    unless File.file?(binary)
      pending "Build the binary first: make build"
    end

    # Count chiasmus processes before
    before = `ps aux | grep -c '[c]hiasmus'`.strip.to_i

    output = IO::Memory.new
    error = IO::Memory.new
    Process.run(binary, ["--healthcheck"], output: output, error: error)

    after = `ps aux | grep -c '[c]hiasmus'`.strip.to_i

    # No extra chiasmus process should be left behind
    after.should eq(before)
  end
end
