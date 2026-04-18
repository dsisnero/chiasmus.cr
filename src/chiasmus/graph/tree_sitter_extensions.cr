require "tree_sitter"

module TreeSitter
  # Extensions to TreeSitter::Node to add missing methods
  # Note: Many methods that were previously here are now in the patched tree_sitter shard
  struct Node
    # Get children as an array (for random access)
    # This is not in the patched shard, so we keep it here
    # Note: children.to_a is equivalent but creates a new iterator
    def children_array : Array(Node)
      # Use children.to_a for consistency with iterator API
      children.to_a
    end

    # Helper to get node text with source context
    # This provides a simpler interface than the patched shard's text method
    def text_with_source(source : String) : String
      # Call the original text method
      start_pos = start_byte
      end_pos = end_byte
      slice = source.byte_slice(start_pos, end_pos - start_pos)
      @@string_pool.get(slice)
    end

    # Convenience method to get field name for child with Int32 index
    # The patched shard has field_name_for_child with UInt32 parameter
    def field_name_for_child_int(index : Int32) : String?
      return nil if index < 0 || index >= child_count
      field_name_for_child(index.to_u32)
    end
  end

  # Extensions to TreeSitter::Language
  class Language
    # Get the field id for a field name
    # This is not in the patched shard
    def field_id_for_name(field_name : String) : LibTreeSitter::TSFieldId
      LibTreeSitter.ts_language_field_id_for_name(self, field_name, field_name.bytesize.to_u32)
    end
  end
end
