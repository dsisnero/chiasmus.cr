ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"

require "./chiasmus/plan"

exit Chiasmus::Plan::CLI.run(ARGV)
