#!/usr/bin/env crystal
# chiasmus-complete: the completion gate for a port.
#
# Given the curated inventory + source facts (+ Crystal facts or a parity
# report), reports which reachable inventory rows are complete vs incomplete and
# exits 2 while reachable work remains. A row is complete when it is `ported`,
# has a Crystal match, is a structural match, and is tested. See
# docs/CLI-BINARIES.md.
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/complete"

exit Chiasmus::Complete::CLI.run(ARGV)
