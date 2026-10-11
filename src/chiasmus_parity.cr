#!/usr/bin/env crystal
# chiasmus-parity: curated-ledger parity report + reconciliation/diff formats.
#
# Reads a curated inventory and reports per-row parity against the Crystal port,
# or emits alternative formats for reconciliation: maps (maps_to), maps-prolog
# (self-contained Prolog gate), surfaces (typed arity diff), divergences
# (ledger-vs-structure). See docs/CLI-BINARIES.md and docs/parity-rule-data.md.
ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/parity"

exit Chiasmus::Parity::CLI.run(ARGV)
