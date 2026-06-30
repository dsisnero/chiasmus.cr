#!/usr/bin/env crystal
#
# Warms the extraction cache by sending all .cr files in a single
# chiasmus_graph call, letting the server's BoundedWork.map_ordered
# extract them in parallel internally.
#
# Usage: crystal run scripts/warm_cache.cr
#        make warm-cache        (after build_release)
#
# The cache lives in ~/.cache/chiasmus/<repo_sha>/ and survives
# server restarts.  Once warmed, graph tool calls hit instantly.

require "process"
require "json"

BINARY = File.join(__DIR__, "..", "bin", "chiasmus")
unless File.exists?(BINARY) && File.info(BINARY).permissions.owner_execute?
  STDERR.puts "Binary not found: #{BINARY}"
  STDERR.puts "Run 'make build_release' first."
  exit 1
end

src_dir = File.join(__DIR__, "..", "src")
spec_dir = File.join(__DIR__, "..", "spec")
files = (Dir.glob("#{src_dir}/**/*.cr") + Dir.glob("#{spec_dir}/**/*.cr"))
  .reject(&.includes?("._")).sort!
total = files.size

puts "Warming extraction cache for #{total} files in one request..."
puts "Binary: #{BINARY}"

paths = files.map { |path| File.realpath(path) }

call = {
  "jsonrpc" => "2.0",
  "id"      => 2,
  "method"  => "tools/call",
  "params"  => {
    "name"      => "chiasmus_graph",
    "arguments" => {
      "files"    => paths,
      "analysis" => "summary",
    },
  },
}

init = {
  "jsonrpc" => "2.0",
  "id"      => 1,
  "method"  => "initialize",
  "params"  => {
    "protocolVersion" => "2024-11-05",
    "capabilities"    => {} of String => JSON::Any,
    "clientInfo"      => {"name" => "warm-cache", "version" => "1.0"},
  },
}

input = IO::Memory.new(init.to_json + "\n" + call.to_json + "\n")

process = Process.new(
  BINARY,
  input: Process::Redirect::Pipe,
  output: Process::Redirect::Pipe,
  error: Process::Redirect::Close,
)

# Write both JSON-RPC messages, then close stdin to signal EOF.
process.input.write(input.to_slice)
process.input.close

# Read responses so the child can't block on a full pipe.
process.output.gets_to_end
status = process.wait

if status.success?
  puts "Done. #{total} files should be cached."
else
  STDERR.puts "Graph call failed (exit #{status.exit_code})."
  # Check stderr traces — in a real run these go to stderr, but we closed it.
  # Re-run with error visible for debugging:
  STDERR.puts "Debug: #{BINARY} < input_file"
  exit 1
end
