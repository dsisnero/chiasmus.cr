require "../../spec_helper"
require "process"

describe "Chiasmus Healthcheck CLI" do
  it "returns exit code 0 for a working chiasmus server via stdio" do
    binary = File.join(Dir.current, "bin", "chiasmus")

    # First verify the binary exists
    unless File.file?(binary)
      pending "Build the binary first: make build"
    end

    ENV["CHIASMUS_BIN"] = binary

    output = IO::Memory.new
    error = IO::Memory.new

    status = Process.run(binary, ["--healthcheck"], output: output, error: error)

    status.exit_code.should eq(0)
    output.to_s.should contain("healthcheck OK")
  end
end
