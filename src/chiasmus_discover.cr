#!/usr/bin/env crystal
# CLI for Tree-sitter-based source code discovery.
# Outputs declarations in TSV format matching parity inventory conventions.
#
# Usage: crystal run src/chiasmus_discover.cr -- [options]
#   --language LANG    Language to discover (e.g. "typescript")
#   --dir DIR          Source directory to scan
#   --parser MODE      Parser mode: auto|tree-sitter|regex (default: auto)
#   --tsv              Output TSV format (default)

require "./chiasmus/discover_cli"

exit Chiasmus::DiscoverCLI.run(ARGV)
