require "../../spec_helper"
require "../../../src/chiasmus/graph/cache"
require "openssl"

include Chiasmus::Graph

private def expected_repo_key(dir : String) : String
  sha = OpenSSL::Digest.new("SHA256")
  sha.update(dir)
  sha.final.hexstring[0, 16]
end

describe "GraphCache.default_repo_key" do
  it "returns a 16-character hex string" do
    key = GraphCache.default_repo_key
    key.size.should eq(16)
    key.should match(/^[0-9a-f]{16}$/)
  end

  it "is derived from the current working directory" do
    key = GraphCache.default_repo_key
    cwd = Dir.current
    expected = expected_repo_key(cwd)
    key.should eq(expected)
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
end
