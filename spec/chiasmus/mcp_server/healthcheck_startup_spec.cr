require "../../spec_helper"
require "process"

describe "Chiasmus server async startup healthcheck" do
  it "logs self-healthcheck to stderr after server starts (in-memory transport)" do
    cmd, args = chiasmus_cli_command

    proc = Process.new(
      cmd,
      args: args,
      env: chiasmus_cli_env,
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )

    begin
      # Write initialize and keep stdin open
      pipe_in = proc.input
      pipe_in.puts %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n)
      pipe_in.flush

      # Collect stderr for up to 5 seconds
      stderr_lines = [] of String
      ch = Channel(String?).new
      spawn do
        loop do
          line = proc.error.gets
          break unless line
          ch.send(line)
        end
        ch.send(nil)
      end

      loop do
        select
        when line = ch.receive
          break unless line
          stderr_lines << line
          break if stderr_lines.size >= 20
        when timeout(20.seconds)
          break
        end
      end

      combined = stderr_lines.join("\n")

      combined.should contain("Starting chiasmus")
      # The async healthcheck should appear in stderr after a short delay
      combined.should contain("healthcheck")
    ensure
      proc.terminate rescue nil
    end
  end
end
