require "../../spec_helper"
require "../../../src/chiasmus/solvers/prolog_solver"

include Chiasmus::Solvers

describe PrologUtils do
  describe ".normalize_query" do
    it "returns bare query unchanged" do
      PrologUtils.normalize_query("member(X, [a,b,c])").should eq "member(X, [a,b,c])"
    end

    it "strips ?- prefix" do
      PrologUtils.normalize_query("?- member(X, [a,b,c])").should eq "member(X, [a,b,c])"
    end

    it "strips trailing period" do
      PrologUtils.normalize_query("member(X, [a,b,c]).").should eq "member(X, [a,b,c])"
    end

    it "strips both prefix and suffix" do
      PrologUtils.normalize_query("?- member(X, [a,b,c]).").should eq "member(X, [a,b,c])"
    end

    it "returns empty for whitespace" do
      PrologUtils.normalize_query("   ").should eq ""
    end
  end

  describe ".format_bindings" do
    it "returns 'true' for empty bindings" do
      PrologUtils.format_bindings({} of String => String).should eq "true"
    end

    it "formats single binding" do
      PrologUtils.format_bindings({"X" => "42"}).should eq "X = 42"
    end

    it "formats multiple bindings" do
      PrologUtils.format_bindings({"X" => "42", "Y" => "hello"}).should contain "X = 42"
    end
  end

  describe ".term_to_prolog_string" do
    it "renders nil as underscore" do
      PrologUtils.term_to_prolog_string(JSON.parse("null")).should eq "_"
    end

    it "renders atoms unchanged" do
      PrologUtils.term_to_prolog_string(JSON.parse(%("knight"))).should eq "knight"
    end

    it "renders numbers" do
      PrologUtils.term_to_prolog_string(JSON.parse("42")).should eq "42"
    end

    it "quotes non-bare atoms" do
      PrologUtils.term_to_prolog_string(JSON.parse(%("Hello World"))).should eq "'Hello World'"
    end

    it "renders empty list" do
      PrologUtils.term_to_prolog_string(JSON.parse("[]")).should eq "[]"
    end

    it "renders compound terms" do
      PrologUtils.term_to_prolog_string(JSON.parse(%({"functor":"foo","args":[42,"bar"]}))).should eq "foo(42, bar)"
    end
  end
end

describe CapReachedError do
  it "is an Exception" do
    (CapReachedError.new).should be_a Exception
  end
end

describe LimitExceededError do
  it "is an Exception" do
    (LimitExceededError.new).should be_a Exception
  end
end
