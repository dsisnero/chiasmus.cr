module Chiasmus
  module Graph
    module Names
      extend self

      def owner_name(qualified_name : String) : String?
        parts = qualified_name.split('.')
        return nil if parts.size < 2

        parts[0...-1].join(".")
      end

      def simple_name(qualified_name : String) : String
        qualified_name.split('.').last
      end

      def merge_containment_names(parent_name : String, child_name : String) : String
        return child_name if child_name == parent_name

        parent_segments = parent_name.split('.')
        child_segments = child_name.split('.')
        overlap = overlap_size(parent_segments, child_segments)
        merged_segments = parent_segments + child_segments[overlap..]
        merged_segments.join(".")
      end

      private def overlap_size(parent_segments : Array(String), child_segments : Array(String)) : Int32
        max_overlap = Math.min(parent_segments.size, child_segments.size)

        max_overlap.downto(1) do |count|
          parent_suffix = parent_segments[(parent_segments.size - count)..]
          child_prefix = child_segments[0, count]
          return count if parent_suffix == child_prefix
        end

        0
      end
    end
  end
end
