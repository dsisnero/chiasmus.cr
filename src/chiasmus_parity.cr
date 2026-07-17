ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/parity"

exit Chiasmus::Parity::CLI.run(ARGV)
