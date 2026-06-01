# Merkle Tree — ported from vendor/merkletree/merkletree/merkle_tree.go
#
# SHA-256 based binary Merkle tree supporting:
# - Bottom-up tree construction from data blocks
# - O(log n) inclusion proof generation via parent pointers
# - Constant-time proof verification
#
# Used by CodeIndex for efficient incremental indexing:
# hash each CodeDocument → Merkle leaf → root hash summarizes index state.
# On re-index, compare hashes to identify only changed documents.

require "digest/sha256"
require "crypto/subtle"

module Chiasmus
  # SHA-256 Merkle tree for content-addressable data integrity.
  #
  # ```
  # tree = MerkleTree.new([data1, data2, data3, data4])
  # proof = tree.generate_proof(2)                        # O(log n)
  # MerkleTree.verify_proof(data3, proof, tree.root_hash) # => true
  # ```
  class MerkleTree
    # A node in the Merkle tree with parent pointers for O(log n) proof walking.
    class Node
      getter hash : Bytes
      getter data : Bytes?
      getter left : Node?
      getter right : Node?
      property parent : Node?
      property is_left : Bool

      def initialize(
        @hash : Bytes,
        @data : Bytes? = nil,
        @left : Node? = nil,
        @right : Node? = nil,
      )
        @parent = nil
        @is_left = false
      end
    end

    # A sibling hash with direction for proof verification.
    struct ProofElement
      getter hash : Bytes
      getter is_left : Bool # true if this hash should be on the left during verification

      def initialize(@hash : Bytes, @is_left : Bool)
      end
    end

    getter root : Node
    getter leaves : Array(Node)

    # Build a Merkle tree from data blocks.
    # Each block becomes a leaf node; internal nodes combine child hashes.
    # Odd leaf-count duplicates the last node to form a pair.
    #
    # Raises ArgumentError if data is empty.
    def initialize(data_blocks : Array(Bytes))
      raise ArgumentError.new("cannot create empty merkle tree") if data_blocks.empty?

      @leaves = data_blocks.map do |data|
        hash = Digest::SHA256.digest(data)
        Node.new(hash: hash, data: data)
      end

      @root = build_tree(@leaves)
    end

    # The Merkle root hash — a cryptographic summary of all data.
    def root_hash : Bytes
      @root.hash
    end

    # Generate an inclusion proof for the leaf at `index`.
    # O(log n) — walks parent pointers from leaf to root.
    # Raises IndexError if index is out of bounds.
    def generate_proof(index : Int32) : Array(ProofElement)
      if index < 0 || index >= @leaves.size
        raise IndexError.new("index #{index} out of range [0, #{@leaves.size})")
      end

      proof = [] of ProofElement
      current = @leaves[index]

      while parent = current.parent
        sibling = current.is_left ? parent.right : parent.left
        sibling.try do |s|
          # Sibling position is opposite of current relative to parent
          proof << ProofElement.new(
            hash: s.hash,
            is_left: !current.is_left,
          )
        end
        current = parent
      end

      proof
    end

    # Verify that `data_block` is a member of a tree with `root_hash`
    # using the provided `proof`. Constant-time comparison for timing safety.
    def self.verify_proof(data_block : Bytes, proof : Array(ProofElement), root_hash : Bytes) : Bool
      return false if data_block.empty? || root_hash.empty?

      current_hash = Digest::SHA256.digest(data_block)

      proof.each do |element|
        combined = if element.is_left
                     element.hash + current_hash
                   else
                     current_hash + element.hash
                   end
        current_hash = Digest::SHA256.digest(combined)
      end

      Crypto::Subtle.constant_time_compare(current_hash, root_hash)
    end

    # Recursively build the tree from leaf level upward.
    # Handles odd node counts by duplicating the last node.
    private def build_tree(nodes : Array(Node)) : Node
      return nodes[0] if nodes.size == 1

      parent_level = [] of Node
      i = 0
      while i < nodes.size
        left = nodes[i]
        right = if i + 1 < nodes.size
                  nodes[i + 1]
                else
                  # Duplicate last node for odd count (copy hash only, no data)
                  Node.new(
                    hash: left.hash.dup,
                    data: nil,
                  )
                end

        combined_hash = Digest::SHA256.digest(left.hash + right.hash)
        parent = Node.new(
          hash: combined_hash,
          left: left,
          right: right,
        )

        left.parent = parent
        left.is_left = true
        right.parent = parent
        right.is_left = false

        parent_level << parent
        i += 2
      end

      build_tree(parent_level)
    end
  end
end
