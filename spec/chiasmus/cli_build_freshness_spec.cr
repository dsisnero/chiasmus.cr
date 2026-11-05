require "../spec_helper"

describe "chiasmus CLI spec binary freshness" do
  it "tracks implementation files used by the subprocess shutdown specs" do
    server = File.join(Dir.current, "src", "chiasmus", "mcp_server", "server.cr")
    chiasmus_cli_sources.should contain(server)
  end
end
