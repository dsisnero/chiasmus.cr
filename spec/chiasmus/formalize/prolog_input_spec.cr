require "../../spec_helper"
require "../../../src/chiasmus/formalize/prolog_input"

include Chiasmus::Formalize

describe PrologInput do
  describe ".extract_query" do
    it "extracts ?- query from last line" do
      input = "parent(alice, bob).\n?- parent(X, bob)."
      result = PrologInput.extract_query(input)
      result[:program].should eq "parent(alice, bob)."
      result[:query].should eq "parent(X, bob)."
    end

    it "returns full text as program with 'true.' query when no ?- found" do
      input = "parent(alice, bob).\nparent(bob, carol)."
      result = PrologInput.extract_query(input)
      result[:program].should eq input
      result[:query].should eq "true."
    end

    it "extracts ?- from last ?- line (ignores lines after)" do
      input = "parent(alice, bob).\n?- parent(X, bob).\n% comment"
      result = PrologInput.extract_query(input)
      result[:program].should eq "parent(alice, bob)."
      result[:query].should eq "parent(X, bob)."
    end

    it "handles ?- with extra whitespace after dash" do
      input = "parent(alice, bob).\n?-\tparent(X, bob)."
      result = PrologInput.extract_query(input)
      result[:query].should eq "parent(X, bob)."
    end

    it "trims trailing whitespace from program" do
      input = "parent(alice, bob).\n\n\n?- parent(X, bob)."
      result = PrologInput.extract_query(input)
      result[:program].should eq "parent(alice, bob)."
    end
  end
end
