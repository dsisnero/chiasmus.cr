require "../../spec_helper"

# Regression for the immortal stdio server.
#
# `MCPServer#run` used to stop the watcher *after* `wg.wait`, but the wait group
# cannot drain until the watcher fiber returns, and the watcher only returns once
# it is stopped. The two were mutually dependent, so a closed MCP transport left
# one polling process alive per session.
private def stdio_server_exits_after_eof(startup_delay : Time::Span) : {Bool, String, Int32?}
  cmd, args = chiasmus_cli_command
  proc = Process.new(
    cmd,
    args: args,
    env: chiasmus_cli_env,
    input: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe,
  )

  stderr_text = IO::Memory.new
  stderr_done = Channel(Nil).new(1)
  spawn do
    IO.copy(proc.error, stderr_text)
  rescue
  ensure
    stderr_done.send(nil) rescue nil
  end

  # stdout is JSON-RPC; drain it so the child can never block on a full pipe.
  spawn do
    IO.copy(proc.output, IO::Memory.new)
  rescue
  end

  proc.input.puts %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"shutdown-spec","version":"1.0"}}})
  proc.input.flush

  sleep(startup_delay) if startup_delay > Time::Span.zero

  # EOF on stdin is what a client does when it goes away.
  proc.input.close

  exit_channel = Channel(Process::Status).new(1)
  spawn do
    exit_channel.send(proc.wait) rescue nil
  end

  status = select
  when value = exit_channel.receive
    value
  when timeout(20.seconds)
    nil
  end

  unless status
    proc.terminate rescue nil
    sleep(1.second)
    proc.signal(Signal::KILL) rescue nil
  end

  select
  when stderr_done.receive
  when timeout(5.seconds)
  end

  {!status.nil?, stderr_text.to_s, status.try(&.exit_code)}
end

describe "chiasmus stdio server shutdown" do
  it "exits after stdin reaches EOF" do
    exited, stderr_text, exit_code = stdio_server_exits_after_eof(Time::Span.zero)

    exited.should be_true
    exit_code.should eq(0)
    stderr_text.should contain("[Chiasmus] MCP server shutting down")
  end

  it "exits after stdin reaches EOF while the file watcher is running" do
    exited, stderr_text, exit_code = stdio_server_exits_after_eof(4.seconds)

    exited.should be_true
    exit_code.should eq(0)
    # Guards the scenario that leaked: the watcher fiber had already started.
    stderr_text.should contain("file watcher started")
    stderr_text.should contain("[Chiasmus] MCP server shutting down")
  end
end
