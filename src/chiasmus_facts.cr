#!/usr/bin/env crystal
# CLI for tree-sitter-based code-graph FACT extraction.
#
# Emits layer-A Prolog facts (defines/5, calls/2, imports/3, exports/2,
# contains/2, entry_point/1 + derived rules) for any language we have a grammar
# for. This is the structural/relationship layer used to plan a port and verify
# completeness. See plans/parity_skills.md.
#
# Usage: chiasmus-facts --language LANG --dir DIR [options]
#   --language LANG        Language to analyze (default: crystal)
#   --dir DIR              Source directory to scan (default: .)
#   --entry-point NAME     Entry point for dead-code/reachability (repeatable)
#   --insights             Also emit community/2, cohesion/2, hub/2, bridge/2
#   --cache-dir DIR        Enable persistent per-file extraction cache in DIR
#   --repo-key KEY         Override cache repo key
#   --cache-max-bytes N    Maximum bytes to retain in the cache repo
#   --help, -h             Show this help
#
# Examples:
#   chiasmus-facts --language typescript --dir vendor/chiasmus/src > vendor.pl
#   chiasmus-facts --language crystal    --dir src                 > port.pl

require "./chiasmus/facts_cli"

exit Chiasmus::FactsCLI.run(ARGV)
