#!/usr/bin/env crystal
# CLI for managing tree-sitter grammars in Chiasmus

# Prevent tree-sitter-manager from hijacking CLI args before our parser runs
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

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
