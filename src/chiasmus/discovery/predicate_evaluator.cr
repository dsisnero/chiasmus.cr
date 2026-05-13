require "tree_sitter"

module Chiasmus
  module Discovery
    # Evaluates tree-sitter query predicates against matched captures.
    #
    # Standard predicates (#eq?, #not-eq?, #match?, #not-match?) are handled
    # by the tree-sitter C engine and are re-evaluated here for explicit control.
    # Custom predicates (#select-adjacent!, #has-type?, #has-parent?,
    # #set!, #lineage-from-name!, #strip!) provide the codeium-parse-compatible
    # functionality on top of the tree-sitter engine.
    module PredicateEvaluator
      # Evaluate all predicates for a given match against the source text.
      #
      # Returns `true` if the match passes all filter predicates.
      # Modifies `metadata` hash in-place for #set! predicates.
      # Populates `adjacent` with nodes selected by #select-adjacent!.
      def self.evaluate_match_predicates(
        query : TreeSitter::Query,
        match : TreeSitter::Match,
        source : String,
        metadata : Hash(String, String),
        adjacent : Hash(String, Array(TreeSitter::Node)),
      ) : Bool
        predicates = query.predicates_for_pattern(match.pattern_index)
        return true if predicates.empty?

        captures = match.captures

        predicates.each do |pred|
          case pred.name
          when "eq?"
            return false unless eval_eq?(pred, captures, source)
          when "not-eq?"
            return false unless eval_not_eq?(pred, captures, source)
          when "match?"
            return false unless eval_match?(pred, captures, source)
          when "not-match?"
            return false unless eval_not_match?(pred, captures, source)
          when "has-type?"
            return false unless eval_has_type?(pred, captures)
          when "has-parent?"
            return false unless eval_has_parent?(pred, captures)
          when "not-has-parent?"
            return false unless eval_not_has_parent?(pred, captures)
          when "set!"
            eval_set!(pred, captures, source, metadata)
          when "select-adjacent!"
            eval_select_adjacent!(pred, captures, adjacent)
          when "lineage-from-name!"
            eval_lineage_from_name!(pred, captures, source, metadata)
          when "strip!"
            eval_strip!(pred, captures, source, metadata)
          else
            # Unknown predicates pass through (non-fatal)
          end
        end

        true
      end

      # Filter predicates

      private def self.eval_eq?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture? && pred.args[1].string?

        cap_name = pred.args[0].value
        expected = pred.args[1].value

        captures.any? { |cap| cap.rule == cap_name && cap.node.text(source) == expected }
      end

      private def self.eval_not_eq?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture? && pred.args[1].string?

        cap_name = pred.args[0].value
        unexpected = pred.args[1].value

        !captures.any? { |cap| cap.rule == cap_name && cap.node.text(source) == unexpected }
      end

      private def self.eval_match?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture? && pred.args[1].string?

        cap_name = pred.args[0].value
        pattern = pred.args[1].value

        captures.any? { |cap| cap.rule == cap_name && cap.node.text(source) =~ /#{pattern}/ }
      rescue
        true
      end

      private def self.eval_not_match?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture? && pred.args[1].string?

        cap_name = pred.args[0].value
        pattern = pred.args[1].value

        !captures.any? { |cap| cap.rule == cap_name && cap.node.text(source) =~ /#{pattern}/ }
      rescue
        true
      end

      # Node-type predicate: checks that a capture node's type is one of the listed types.
      private def self.eval_has_type?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture)) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture?

        cap_name = pred.args[0].value
        allowed_types = pred.args.skip(1).select(&.string?).map(&.value)

        captures.any? { |cap| cap.rule == cap_name && allowed_types.includes?(cap.node.type) }
      end

      # Check that a capture node's parent has one of the listed types.
      private def self.eval_has_parent?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture)) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture?

        cap_name = pred.args[0].value
        parent_types = pred.args.skip(1).select(&.string?).map(&.value)

        captures.any? do |cap|
          next unless cap.rule == cap_name
          parent = cap.node.parent
          parent && parent_types.includes?(parent.type)
        end
      end

      # Check that a capture node's parent does NOT have the given type.
      private def self.eval_not_has_parent?(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture)) : Bool
        return true if pred.args.size < 2
        return true unless pred.args[0].capture?

        cap_name = pred.args[0].value
        excluded_types = pred.args.skip(1).select(&.string?).map(&.value)

        !captures.any? do |cap|
          next false unless cap.rule == cap_name
          parent = cap.node.parent
          parent && excluded_types.includes?(parent.type)
        end
      end

      # Metadata predicates

      # Set a metadata key/value on a capture. The value comes from a string or another capture.
      private def self.eval_set!(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String, metadata : Hash(String, String))
        return if pred.args.size < 2

        key = if pred.args[0].capture?
                cap = captures.find(&.rule.==(pred.args[0].value))
                cap.try(&.node.text(source)) || pred.args[0].value
              else
                pred.args[0].value
              end

        value = if pred.args.size > 2 && pred.args[2].capture?
                  cap = captures.find(&.rule.==(pred.args[2].value))
                  cap.try(&.node.text(source)) || ""
                elsif pred.args.size > 2 && pred.args[2].string?
                  pred.args[2].value
                elsif pred.args[1].capture?
                  cap = captures.find(&.rule.==(pred.args[1].value))
                  cap.try(&.node.text(source)) || ""
                elsif pred.args[1].string?
                  pred.args[1].value
                else
                  ""
                end

        metadata[key] = value
      end

      # Select adjacent siblings: given a "from" capture and a "to" capture rule,
      # collect nodes in the "from" capture that are previous siblings of nodes
      # in the "to" capture (used for doc comments before definitions).
      private def self.eval_select_adjacent!(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), adjacent : Hash(String, Array(TreeSitter::Node)))
        return if pred.args.size < 2
        return unless pred.args[0].capture? && pred.args[1].capture?

        from_rule = pred.args[0].value
        to_rule = pred.args[1].value

        from_caps = captures.select(&.rule.==(from_rule))
        to_caps = captures.select(&.rule.==(to_rule))

        return if from_caps.empty? || to_caps.empty?

        selected = [] of TreeSitter::Node
        to_caps.each do |to_cap|
          sibling = to_cap.node.prev_sibling
          while sibling
            if from_caps.any? { |from_cap| from_cap.node.start_byte == sibling.try(&.start_byte) }
              selected << sibling
            end
            sibling = sibling.prev_sibling
          end
        end

        adjacent[from_rule] = selected unless selected.empty?
      end

      # Parse lineage from capture name using a delimiter.
      # E.g., "a::b::c" with delimiter "::" → lineage = ["a", "b", "c"]
      private def self.eval_lineage_from_name!(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String, metadata : Hash(String, String))
        return if pred.args.size < 2
        return unless pred.args[0].capture? && pred.args[1].string?

        cap_name = pred.args[0].value
        delimiter = pred.args[1].value

        cap = captures.find(&.rule.==(cap_name))
        return unless cap

        parts = cap.node.text(source).split(delimiter)
        metadata["codeium.lineage"] = parts.join(" ")
        metadata["codeium.lineage_count"] = parts.size.to_s
      end

      # Strip characters from capture text and store in metadata.
      private def self.eval_strip!(pred : TreeSitter::Predicate, captures : Array(TreeSitter::Capture), source : String, metadata : Hash(String, String))
        return if pred.args.size < 2
        return unless pred.args[0].capture?

        cap_name = pred.args[0].value
        chars = pred.args[1].string? ? pred.args[1].value : ""

        cap = captures.find(&.rule.==(cap_name))
        return unless cap

        stripped = cap.node.text(source).strip(chars)
        metadata["#{cap_name}.stripped"] = stripped
      end

      # Find the doc comment capture for a definition capture within a match.
      def self.doc_for_capture(match : TreeSitter::Match, doc_rule : String) : String?
        match.captures.find(&.rule.==(doc_rule)).try do |cap|
          cap.node.to_s(IO::Memory.new).to_s
        end
      end

      # Extract doc text from a capture by getting the node text minus comment prefixes.
      def self.doc_text(capture : TreeSitter::Capture?, source : String) : String?
        return nil unless capture
        text = capture.node.text(source)
        return nil if text.empty?

        lines = text.lines.map(&.strip)
        # Strip common comment prefixes
        cleaned = lines.map do |line|
          line.lchop?("// ") || line.lchop?("/// ") || line.lchop?("//") ||
            line.lchop?("# ") || line.lchop?("#") ||
            line.lchop?("-- ") || line.lchop?("--") ||
            line.lchop?("% ") || line.lchop?("%") ||
            line.lchop?("; ") || line.lchop?(";") ||
            line
        end
        cleaned.join("\n").presence
      end

      # Resolve a capture's text from a match.
      def self.capture_text(match : TreeSitter::Match, rule : String, source : String) : String?
        match.captures.find(&.rule.==(rule)).try(&.node.text(source))
      end

      # Get the node for a capture rule in a match.
      def self.capture_node(match : TreeSitter::Match, rule : String) : TreeSitter::Node?
        match.captures.find(&.rule.==(rule)).try(&.node)
      end
    end
  end
end
