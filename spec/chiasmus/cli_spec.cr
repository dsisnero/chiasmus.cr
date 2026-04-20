require "spec"
require "file_utils"
require "../../src/chiasmus/cli"

describe Chiasmus::CLI do
  describe "command parsing" do
    pending "shows help for unknown command" do
      # This is hard to test without mocking or capturing stdout
      # We'll rely on integration tests instead
    end
  end

  describe "add_grammar" do
    pending "installs grammar from git URL" do
    end

    pending "installs grammar from npm package" do
    end

    pending "installs grammar from local directory" do
    end

    pending "fails for invalid URL" do
    end

    pending "fails for unsupported package" do
    end
  end

  describe "remove_grammar" do
    pending "removes installed grammar" do
    end

    pending "removes grammar metadata" do
    end

    pending "fails for non-existent grammar" do
    end

    pending "forces removal with --force flag" do
    end
  end

  describe "show_status" do
    pending "shows installed grammars" do
    end

    pending "shows version information" do
    end

    pending "shows update status with --verbose" do
    end

    pending "shows empty status when no grammars installed" do
    end
  end

  describe "update_grammars" do
    pending "checks for updates" do
    end

    pending "updates outdated grammars" do
    end

    pending "shows dry run with --dry-run" do
    end

    pending "updates all grammars with --all" do
    end
  end
end
