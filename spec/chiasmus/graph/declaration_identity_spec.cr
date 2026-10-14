require "../../spec_helper"
require "../../../src/chiasmus/graph/declaration_identity"

include Chiasmus::Graph

private def declaration_input(
  kind : String = "method",
  name : String = "render",
  overload_key : String? = "(value: String)",
  disambiguator : String? = nil,
) : DeclarationIdentityInput
  DeclarationIdentityInput.new(
    language: "crystal",
    namespace: "Example",
    owner_chain: ["Widget"],
    kind: kind,
    name: name,
    overload_key: overload_key,
    disambiguator: disambiguator,
  )
end

describe Chiasmus::Graph::DeclarationIdentity do
  it "creates the same declaration ID in separate checkout roots" do
    root_a = "/worktrees/one"
    root_b = "/worktrees/two"
    absolute_a = File.join(root_a, "src/widget.cr")
    absolute_b = File.join(root_b, "src/widget.cr")
    logical_a = absolute_a.lchop("#{root_a}/")
    logical_b = absolute_b.lchop("#{root_b}/")
    logical_a.should eq(logical_b)

    before = DeclarationIdentity.declaration_id(declaration_input)
    after = DeclarationIdentity.declaration_id(declaration_input)
    before.should eq(after)
  end

  it "ignores formatting-only source movement" do
    declaration_id = DeclarationIdentity.declaration_id(declaration_input)
    before = Span.new(10, 35, 2, 0, 2, 25)
    after = Span.new(24, 49, 4, 0, 4, 25)
    declaration_id.should eq(DeclarationIdentity.declaration_id(declaration_input))
    DeclarationIdentity.occurrence_id(OccurrenceIdentityInput.new("src/widget.cr", before, "method_definition")).should_not eq(
      DeclarationIdentity.occurrence_id(OccurrenceIdentityInput.new("src/widget.cr", after, "method_definition"))
    )
  end

  it "distinguishes overloads" do
    first = DeclarationIdentity.declaration_id(declaration_input(overload_key: "(value: String)"))
    second = DeclarationIdentity.declaration_id(declaration_input(overload_key: "(value: Int32)"))
    first.should_not eq(second)
  end

  it "distinguishes precise declaration kinds" do
    method_id = DeclarationIdentity.declaration_id(declaration_input(kind: "method"))
    function_id = DeclarationIdentity.declaration_id(declaration_input(kind: "function"))
    method_id.should_not eq(function_id)
  end

  it "uses caller disambiguators for true duplicate declarations" do
    first = DeclarationIdentity.declaration_id(declaration_input(disambiguator: "part-a"))
    second = DeclarationIdentity.declaration_id(declaration_input(disambiguator: "part-b"))
    first.should_not eq(second)
  end

  it "normalizes overload whitespace and logical path separators" do
    canonical = DeclarationIdentity.declaration_id(declaration_input(overload_key: "(value: String)"))
    spaced = DeclarationIdentity.declaration_id(declaration_input(overload_key: " (value:   String) "))
    canonical.should eq(spaced)

    span = Span.new(0, 5, 1, 0, 1, 5)
    first = DeclarationIdentity.occurrence_id(OccurrenceIdentityInput.new("./src/widget.cr", span, "method_definition"))
    second = DeclarationIdentity.occurrence_id(OccurrenceIdentityInput.new("src\\widget.cr", span, "method_definition"))
    first.should eq(second)
  end

  it "rejects absolute paths for occurrence identity" do
    input = OccurrenceIdentityInput.new("/checkout/src/widget.cr", Span.line_range(1), "method")
    expect_raises(ArgumentError) { DeclarationIdentity.occurrence_id(input) }
  end
end
