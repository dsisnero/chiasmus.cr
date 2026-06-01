require "../spec_helper"
require "digest/sha256"

describe Chiasmus::MerkleTree do
  describe ".new" do
    it "rejects empty data" do
      expect_raises(ArgumentError, "cannot create empty merkle tree") do
        Chiasmus::MerkleTree.new([] of Bytes)
      end
    end

    it "builds a single-leaf tree" do
      tree = Chiasmus::MerkleTree.new(["hello".to_slice])

      tree.root.should_not be_nil
      tree.leaves.size.should eq(1)
      tree.leaves[0].data.should eq("hello".to_slice)
    end

    it "builds a two-leaf tree" do
      tree = Chiasmus::MerkleTree.new(["hello".to_slice, "world".to_slice])

      tree.root.should_not be_nil
      tree.leaves.size.should eq(2)
      tree.leaves[0].data.should eq("hello".to_slice)
      tree.leaves[1].data.should eq("world".to_slice)
    end

    it "builds tree with odd number of leaves" do
      tree = Chiasmus::MerkleTree.new(["a".to_slice, "b".to_slice, "c".to_slice])

      tree.root.should_not be_nil
      tree.leaves.size.should eq(3)
    end

    it "builds tree with power-of-two leaves" do
      tree = Chiasmus::MerkleTree.new(["a".to_slice, "b".to_slice, "c".to_slice, "d".to_slice])

      tree.root.should_not be_nil
      tree.leaves.size.should eq(4)
    end
  end

  describe "#root_hash" do
    it "is deterministic — same data gives same root" do
      data = ["tx1".to_slice, "tx2".to_slice, "tx3".to_slice, "tx4".to_slice]

      roots = 5.times.map do
        Chiasmus::MerkleTree.new(data).root_hash
      end

      roots.uniq.size.should eq(1)
    end

    it "matches known test vector" do
      data = ["a".to_slice, "b".to_slice, "c".to_slice, "d".to_slice]

      tree = Chiasmus::MerkleTree.new(data)

      # Manually compute expected root: SHA256(SHA256(SHA256(a)+SHA256(b)) + SHA256(SHA256(c)+SHA256(d)))
      ha = Digest::SHA256.digest("a")
      hb = Digest::SHA256.digest("b")
      hc = Digest::SHA256.digest("c")
      hd = Digest::SHA256.digest("d")

      hab = Digest::SHA256.digest(ha + hb)
      hcd = Digest::SHA256.digest(hc + hd)

      expected = Digest::SHA256.digest(hab + hcd)

      tree.root_hash.should eq(expected)
    end

    it "changes when data changes" do
      data = ["transfer $100".to_slice, "transfer $200".to_slice, "transfer $300".to_slice]

      root1 = Chiasmus::MerkleTree.new(data).root_hash

      data[1] = "transfer $2000".to_slice
      root2 = Chiasmus::MerkleTree.new(data).root_hash
      root2.should_not eq(root1)

      # Small change also changes root
      data[1] = "transfer $200.".to_slice
      root3 = Chiasmus::MerkleTree.new(data).root_hash
      root3.should_not eq(root1)
    end
  end

  describe "#generate_proof" do
    it "generates proofs of correct length" do
      data = ["a".to_slice, "b".to_slice, "c".to_slice, "d".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      (0...data.size).each do |i|
        proof = tree.generate_proof(i)
        proof.size.should eq(2) # log2(4) = 2
      end
    end

    it "rejects negative index" do
      tree = Chiasmus::MerkleTree.new(["a".to_slice, "b".to_slice])

      expect_raises(IndexError) do
        tree.generate_proof(-1)
      end
    end

    it "rejects out-of-bounds index" do
      tree = Chiasmus::MerkleTree.new(["a".to_slice, "b".to_slice])

      expect_raises(IndexError) do
        tree.generate_proof(2)
      end
    end
  end

  describe ".verify_proof" do
    it "verifies valid membership proofs" do
      data = ["alice".to_slice, "bob".to_slice, "charlie".to_slice, "david".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      data.each_with_index do |item, i|
        proof = tree.generate_proof(i)
        result = Chiasmus::MerkleTree.verify_proof(item, proof, tree.root_hash)
        result.should be_true
      end
    end

    it "rejects invalid data with valid proof" do
      data = ["alice".to_slice, "bob".to_slice, "charlie".to_slice, "david".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      proof = tree.generate_proof(0)
      result = Chiasmus::MerkleTree.verify_proof("eve".to_slice, proof, tree.root_hash)
      result.should be_false
    end

    it "rejects valid data with wrong root hash" do
      data = ["alice".to_slice, "bob".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      proof = tree.generate_proof(0)
      wrong_root = Digest::SHA256.digest("wrong")
      result = Chiasmus::MerkleTree.verify_proof(data[0], proof, wrong_root)
      result.should be_false
    end

    it "rejects nil data" do
      tree = Chiasmus::MerkleTree.new(["a".to_slice, "b".to_slice])
      proof = tree.generate_proof(0)

      result = Chiasmus::MerkleTree.verify_proof(Bytes.empty, proof, tree.root_hash)
      result.should be_false
    end

    it "comprehensive verification: valid and invalid cases" do
      data = ["A".to_slice, "B".to_slice, "C".to_slice, "D".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      # Verify known root
      ha = Digest::SHA256.digest("A")
      hb = Digest::SHA256.digest("B")
      hc = Digest::SHA256.digest("C")
      hd = Digest::SHA256.digest("D")

      hab = Digest::SHA256.digest(ha + hb)
      hcd = Digest::SHA256.digest(hc + hd)
      expected = Digest::SHA256.digest(hab + hcd)

      tree.root_hash.should eq(expected)

      # Valid proofs for each leaf
      [
        {0, "A".to_slice, true},
        {1, "B".to_slice, true},
        {2, "C".to_slice, true},
        {3, "D".to_slice, true},
        {0, "X".to_slice, false},
        {1, "A".to_slice, false},
      ].each do |(idx, item, expected_valid)|
        proof = tree.generate_proof(idx)
        result = Chiasmus::MerkleTree.verify_proof(item, proof, tree.root_hash)
        result.should eq(expected_valid)
      end
    end
  end

  describe "tree properties" do
    it "leaf nodes carry data" do
      data = ["1".to_slice, "2".to_slice, "3".to_slice, "4".to_slice,
              "5".to_slice, "6".to_slice, "7".to_slice, "8".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      tree.leaves.each_with_index do |leaf, i|
        leaf.data.should_not be_nil
        leaf.data.should eq(data[i])
      end
    end

    it "internal nodes have no data" do
      data = ["1".to_slice, "2".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      tree.root.data.should be_nil
      tree.root.hash.should_not be_nil
    end

    it "leaf count matches input count" do
      data = ["a".to_slice, "b".to_slice, "c".to_slice, "d".to_slice, "e".to_slice]
      tree = Chiasmus::MerkleTree.new(data)

      tree.leaves.size.should eq(5)
    end
  end
end
