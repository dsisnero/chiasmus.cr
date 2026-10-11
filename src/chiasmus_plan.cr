#!/usr/bin/env crystal
# chiasmus-plan: plan a port from source facts.
#
# Subcommands rank | safe | slice | seed-parity | track | audit | refresh turn a
# source facts file (from chiasmus-facts) plus the curated ledger into an
# ordered, reviewable port plan. See docs/CLI-BINARIES.md.
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/plan"

exit Chiasmus::Plan::CLI.run(ARGV)
