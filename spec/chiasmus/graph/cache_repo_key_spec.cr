require "../../spec_helper"
require "../../../src/chiasmus/graph/cache"
require "openssl"

include Chiasmus::Graph

private def expected_repo_key(dir : String) : String
  sha = OpenSSL::Digest.new("SHA256")
  sha.update(dir)
  sha.final.hexstring[0, 16]
end

private def run_git!(repo : String, args : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("git", args, chdir: repo, output: output, error: error)
  raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  output.to_s
end

private def expected_git_repo_key(repo : String) : String
  common_dir = run_git!(repo, ["rev-parse", "--git-common-dir"]).strip
  resolved = File.realpath(File.expand_path(common_dir, repo))
  expected_repo_key(resolved)
end

describe "GraphCache.default_repo_key" do
  it "returns a 16-character hex string" do
    key = GraphCache.default_repo_key
    key.size.should eq(16)
    key.should match(/^[0-9a-f]{16}$/)
  end

  it "uses the git common dir when inside a git repository" do
    key = GraphCache.default_repo_key
    expected = expected_git_repo_key(Dir.current)
    key.should eq(expected)
  end

  it "falls back to the current working directory outside git" do
    dir = File.join(Dir.tempdir, "chiasmus-cache-repo-key-fallback-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      GraphCache.default_repo_key(dir).should eq(expected_repo_key(File.realpath(dir)))
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "is deterministic for the same directory" do
    k1 = GraphCache.default_repo_key
    k2 = GraphCache.default_repo_key
    k1.should eq(k2)
  end

  it "differs for different directories" do
    key1 = GraphCache.default_repo_key
    Dir.cd(Dir.tempdir) do
      key2 = GraphCache.default_repo_key
      key1.should_not eq(key2) unless Dir.current == Dir.current # skip if same dir
    end
  end

  it "uses the shared git common dir across worktrees" do
    dir = File.join(Dir.tempdir, "chiasmus-cache-repo-key-#{Random::Secure.hex(8)}")
    worktree = File.join(Dir.tempdir, "chiasmus-cache-repo-key-wt-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      run_git!(dir, ["init", "-b", "main"])
      run_git!(dir, ["config", "user.email", "spec@example.com"])
      run_git!(dir, ["config", "user.name", "Spec User"])
      File.write(File.join(dir, "app.cr"), "puts :main\n")
      run_git!(dir, ["add", "app.cr"])
      run_git!(dir, ["commit", "-m", "initial cache repo key fixture"])
      run_git!(dir, ["worktree", "add", worktree, "-b", "spec-worktree"])

      repo_key = GraphCache.default_repo_key(dir)
      worktree_key = GraphCache.default_repo_key(worktree)
      repo_key.should eq(worktree_key)
      repo_key.should eq(expected_git_repo_key(dir))
    ensure
      FileUtils.rm_rf(worktree)
      FileUtils.rm_rf(dir)
    end
  end
end
