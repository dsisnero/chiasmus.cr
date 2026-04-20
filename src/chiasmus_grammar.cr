#!/usr/bin/env crystal
# CLI for managing tree-sitter grammars in Chiasmus

require "./chiasmus/cli"

# Main entry point
begin
  cli = Chiasmus::CLI.new
  cli.run(ARGV)
rescue e : Exception
  STDERR.puts "Error: #{e.message}"
  STDERR.puts e.backtrace.join("\n") if ENV["DEBUG"]?
  exit 1
end
