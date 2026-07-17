ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/complete"

exit Chiasmus::Complete::CLI.run(ARGV)
