#!/usr/bin/env crystal

# Install the Chiasmus grammar baseline through the manager-backed CLI.
# `compile` is intentionally not used here: it requires checked-out grammar
# sources and the native `tree-sitter` CLI, while `batch` downloads, builds,
# and caches grammar libraries through tree-sitter-manager.

require "process"

# Default grammars for Chiasmus builds and distributions. Racket files use the
# Scheme grammar; Common Lisp covers .lisp, .lsp, .cl, and .asd files.
DEFAULT_LANGUAGES = [
  "ruby",
  "python",
  "java",
  "go",
  "rust",
  "scala",
  "csharp",
  "javascript",
  "typescript",
  "tsx",
  "crystal",
  "scheme",
  "commonlisp",
]

def run_command(cmd : String, args : Array(String) = [] of String) : Bool
  puts "Running: #{cmd} #{args.join(" ")}" if ENV["DEBUG"]?

  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(cmd, args,
    output: output,
    error: error
  )

  unless status.success?
    puts "Command failed: #{cmd} #{args.join(" ")}"
    puts "Error: #{error.to_s}" unless error.to_s.empty?
    return false
  end

  true
end

def main
  puts "Setting up required grammars using chiasmus-grammar CLI..."
  puts "Grammars are downloaded and cached by tree-sitter-manager."
  puts

  # Build the CLI if needed
  unless File.exists?("bin/chiasmus-grammar")
    puts "Building chiasmus-grammar CLI..."
    unless run_command("crystal", ["build", "--release", "-o", "bin/chiasmus-grammar", "src/chiasmus_grammar.cr"])
      puts "Failed to build chiasmus-grammar CLI"
      exit 1
    end
  end

  unless run_command("bin/chiasmus-grammar", ["batch", DEFAULT_LANGUAGES.join(",")])
    puts "⚠ Grammar installation failed. Re-run with DEBUG=1 for command output."
    exit 1
  end

  puts "✅ All required grammars are available!"
end

main
