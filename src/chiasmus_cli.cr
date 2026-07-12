#!/usr/bin/env crystal

# Prevent tree-sitter-manager from hijacking CLI args before our parser runs
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus"

exit Chiasmus.run_cli(ARGV)
