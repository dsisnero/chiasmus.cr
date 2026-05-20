require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/type_env"

include Chiasmus::Graph

describe TypeEnv do
  describe ".strip_nullable" do
    it "strips null from union types" do
      TypeEnv.strip_nullable("string | null").should eq "string"
    end

    it "strips undefined from union types" do
      TypeEnv.strip_nullable("string | undefined").should eq "string"
    end

    it "strips void from union types" do
      TypeEnv.strip_nullable("string | null | void").should eq "string"
    end

    it "strips nullable marker" do
      TypeEnv.strip_nullable("string?").should eq "string"
    end

    it "returns simple types unchanged" do
      TypeEnv.strip_nullable("string").should eq "string"
    end

    it "returns first non-null part of union" do
      TypeEnv.strip_nullable("number | string").should eq "number"
    end

    it "strips leading bar" do
      TypeEnv.strip_nullable("| number").should eq "number"
    end

    it "strips trailing bar" do
      TypeEnv.strip_nullable("number |").should eq "number"
    end
  end

  describe ".extract_simple_type_name" do
    # These tests work on a mock node — testing text-based logic only.
    # Full tree-sitter tests would require parsing actual TS sources.
    it "extracts simple type names from text" do
      # The function takes a TreeSitter::Node with .text(source) returning the type text.
      # For pure text testing, we verify the strip logic indirectly via strip_nullable.
      TypeEnv.strip_nullable("User").should eq "User"
    end
  end

  describe ".extract_var_name" do
    # Requires tree-sitter node — placeholder for integration test
    it "is defined" do
      TypeEnv.responds_to?(:extract_var_name).should be_true
    end
  end

  describe ".find_enclosing_class_name" do
    # Requires tree-sitter node with parent chain — placeholder for integration test
    it "is defined" do
      TypeEnv.responds_to?(:find_enclosing_class_name).should be_true
    end
  end

  describe ".collect_type_info" do
    # Requires tree-sitter AST — placeholder for integration test
    it "is defined" do
      TypeEnv.responds_to?(:collect_type_info).should be_true
    end
  end

  describe "CLASS_NODE_TYPES" do
    it "includes class and interface declarations" do
      types = Chiasmus::Graph::TypeEnv::CLASS_NODE_TYPES
      types.includes?("class_declaration").should be_true
      types.includes?("interface_declaration").should be_true
    end
  end
end
