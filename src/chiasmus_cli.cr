#!/usr/bin/env crystal
# chiasmus: MCP server entrypoint.
#
# Starts the Model Context Protocol server (graph + formal-verification tools)
# over stdio by default; also supports --version, --healthcheck, and
# --streamable PORT. See docs/CLI-BINARIES.md.

# Prevent tree-sitter-manager from hijacking CLI args before our parser runs
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus"

exit Chiasmus.run_cli(ARGV)
