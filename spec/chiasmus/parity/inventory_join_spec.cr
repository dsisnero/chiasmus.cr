require "../../spec_helper"
require "../../../src/chiasmus/parity/reconcile"

module InventoryJoinSpecSupport
  def self.row(id : String, kind : String, status : String) : Chiasmus::Parity::InventoryRow
    Chiasmus::Parity::InventoryRow.new(
      source_id: id,
      kind: kind,
      status: status,
      crystal_refs: "-",
      notes: "-",
    )
  end

  def self.mapping(name : String, canonical : String, status : String, target : String? = nil) : Chiasmus::Parity::Reconcile::Mapping
    Chiasmus::Parity::Reconcile::Mapping.new(
      source_id: "vendor/#{name}.java::class::#{name}",
      source_name: name,
      source_kind: "class",
      canonical: canonical,
      status: status,
      target_name: target,
    )
  end
end

describe Chiasmus::Parity::InventoryJoin do
  rules = Chiasmus::Parity::Rules::RuleSet.new

  it "flags a ledger-missing row that reconciles structurally" do
    inventory = [InventoryJoinSpecSupport.row("a/COSBase.java::class::COSBase", "class", "missing")]
    mappings = [InventoryJoinSpecSupport.mapping("COSBase", "cos_base", "matched", "Base")]

    row = Chiasmus::Parity::InventoryJoin.divergences(inventory, mappings, rules).first
    row.divergence.should eq("falsely_missing")
    row.map_status.should eq("matched")
    row.target_name.should eq("Base")
  end

  it "flags a ledger-ported row with no structural counterpart" do
    inventory = [InventoryJoinSpecSupport.row("a/Document.java::method::Document.close", "method", "ported")]
    mappings = [
      Chiasmus::Parity::Reconcile::Mapping.new(
        source_id: "vendor/document.java::method::Document.close",
        source_name: "document.close",
        source_kind: "method",
        canonical: "something_else",
        status: "unmapped_source",
      ),
    ]

    row = Chiasmus::Parity::InventoryJoin.divergences(inventory, mappings, rules).first
    row.divergence.should eq("falsely_ported")
    row.map_status.should eq("no_facts")
  end

  it "records no divergence when ledger and structure agree" do
    inventory = [InventoryJoinSpecSupport.row("a/COSBase.java::class::COSBase", "class", "ported")]
    mappings = [InventoryJoinSpecSupport.mapping("COSBase", "cos_base", "matched", "Base")]

    Chiasmus::Parity::InventoryJoin.divergences(inventory, mappings, rules).first.divergence.should eq("-")
  end

  it "treats inventory const rows as compatible with fact variable kinds" do
    Chiasmus::Parity::InventoryJoin.kind_compatible?("const", "variable").should be_true
    Chiasmus::Parity::InventoryJoin.kind_compatible?("enum", "class").should be_true
    Chiasmus::Parity::InventoryJoin.kind_compatible?("method", "class").should be_false
  end
end
