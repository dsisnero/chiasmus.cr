require "../spec_helper"
require "../../scripts/npm_command"

describe NpmCommand do
  it "invokes npm through cmd.exe on Windows" do
    NpmCommand.invocation("npm", ["install", "--no-audit"], true).should eq(
      {ENV["COMSPEC"]? || "cmd.exe", ["/c", "npm", "install", "--no-audit"]}
    )
  end

  it "invokes npx through cmd.exe on Windows" do
    NpmCommand.invocation("npx", ["tree-sitter", "--version"], true).should eq(
      {ENV["COMSPEC"]? || "cmd.exe", ["/c", "npx", "tree-sitter", "--version"]}
    )
  end

  it "invokes native tree-sitter directly on Windows" do
    NpmCommand.invocation("tree-sitter", ["generate"], true).should eq(
      {"tree-sitter", ["generate"]}
    )
  end

  it "uses the executable directly on other platforms" do
    NpmCommand.invocation("npm", ["install"], false).should eq({"npm", ["install"]})
  end
end
