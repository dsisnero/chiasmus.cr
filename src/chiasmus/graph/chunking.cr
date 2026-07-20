require "tree_sitter"
require "./parser"
require "./span"

module Chiasmus
  module Graph
    module Chunking
      extend self

      record CommentInfo,
        text : String,
        span : Span

      record DocstringInfo,
        text : String,
        span : Span

      record ChunkContext,
        language : String,
        chunk_index : Int32,
        total_chunks : Int32,
        node_types : Array(String),
        context_path : Array(String),
        symbols_defined : Array(String),
        comments : Array(CommentInfo),
        docstrings : Array(DocstringInfo),
        has_error_nodes : Bool

      record CodeChunk,
        content : String,
        span : Span,
        context : ChunkContext

      private record RangeSection,
        start_byte : Int32,
        end_byte : Int32,
        node : TreeSitter::Node? = nil do
        def size : Int32
          end_byte - start_byte
        end
      end

      DEF_LIKE_TYPES = {
        "alias",
        "abstract_method_def",
        "annotation_def",
        "class",
        "class_def",
        "const_assign",
        "def",
        "enum",
        "enum_def",
        "fun",
        "fun_def",
        "function",
        "impl",
        "interface",
        "lib",
        "lib_def",
        "macro",
        "macro_def",
        "method",
        "method_def",
        "module",
        "module_def",
        "namespace",
        "singleton_method",
        "struct",
        "struct_def",
        "trait",
        "type",
        "type_def",
        "union_def",
      }.to_set

      COMMENT_LIKE_TYPES = {
        "comment",
        "block_comment",
        "line_comment",
      }.to_set

      def chunk_source(
        source : String,
        file_path : String,
        max_chunk_size : Int32,
        parser = Parser,
      ) : Array(CodeChunk)
        language = parser.language_for_file(file_path) || File.extname(file_path).lstrip('.').downcase
        tree = parser.parse(source, file_path)
        ranges = if tree
                   split_tree(tree.root_node, source, max_chunk_size)
                 else
                   fallback_ranges(source, 0, source.bytesize.to_i32, max_chunk_size)
                 end

        total_chunks = ranges.size.to_i32
        ranges.each_with_index.map do |section, index|
          span = span_for_range(source, section.start_byte, section.end_byte)
          content = slice_bytes(source, section.start_byte, section.end_byte)
          context = if tree
                      collect_chunk_context(tree.root_node, source, language, section.start_byte, section.end_byte, index.to_i32, total_chunks)
                    else
                      ChunkContext.new(
                        language: language,
                        chunk_index: index.to_i32,
                        total_chunks: total_chunks,
                        node_types: [] of String,
                        context_path: [] of String,
                        symbols_defined: [] of String,
                        comments: [] of CommentInfo,
                        docstrings: [] of DocstringInfo,
                        has_error_nodes: false,
                      )
                    end

          CodeChunk.new(
            content: content,
            span: span,
            context: context,
          )
        end.to_a
      end

      private def split_tree(node : TreeSitter::Node, source : String, max_chunk_size : Int32) : Array(RangeSection)
        split_node(node, source, 0, source.bytesize.to_i32, max_chunk_size)
      end

      private def split_node(
        node : TreeSitter::Node,
        source : String,
        start_byte : Int32,
        end_byte : Int32,
        max_chunk_size : Int32,
      ) : Array(RangeSection)
        size = end_byte - start_byte
        return [RangeSection.new(start_byte: start_byte, end_byte: end_byte, node: node)] if size <= max_chunk_size

        children = direct_split_children(node).select do |child|
          child.end_byte.to_i32 > start_byte && child.start_byte.to_i32 < end_byte
        end
        children.sort_by!(&.start_byte)

        return fallback_ranges(source, start_byte, end_byte, max_chunk_size) if children.empty?

        sections = [] of RangeSection
        cursor = start_byte

        children.each do |child|
          child_start = Math.max(child.start_byte.to_i32, start_byte)
          child_end = Math.min(child.end_byte.to_i32, end_byte)
          next if child_end <= child_start

          if cursor < child_start
            sections << RangeSection.new(start_byte: cursor, end_byte: child_start)
          end

          sections << RangeSection.new(start_byte: child_start, end_byte: child_end, node: child)
          cursor = child_end
        end

        if cursor < end_byte
          sections << RangeSection.new(start_byte: cursor, end_byte: end_byte)
        end

        flattened = [] of RangeSection
        sections.each do |section|
          if section.size <= max_chunk_size
            flattened << section
          elsif section.node
            child = section.node || raise "expected split node"
            flattened.concat(split_node(child, source, section.start_byte, section.end_byte, max_chunk_size))
          else
            flattened.concat(fallback_ranges(source, section.start_byte, section.end_byte, max_chunk_size))
          end
        end

        merge_sections(flattened, max_chunk_size)
      end

      private def direct_split_children(node : TreeSitter::Node) : Array(TreeSitter::Node)
        children = [] of TreeSitter::Node

        node.children.each do |child|
          next unless child.named? || comment_like?(child)
          children << child
        end

        children
      end

      private def merge_sections(sections : Array(RangeSection), max_chunk_size : Int32) : Array(RangeSection)
        return sections if sections.size <= 1

        merged = [] of RangeSection
        index = 0

        while index < sections.size
          current = sections[index]

          while index + 1 < sections.size
            next_section = sections[index + 1]
            following = sections[index + 2]?

            break if keep_comment_with_following?(current, next_section, following, max_chunk_size)
            break unless next_section.end_byte - current.start_byte <= max_chunk_size

            current = RangeSection.new(start_byte: current.start_byte, end_byte: next_section.end_byte)
            index += 1
          end

          merged << current
          index += 1
        end

        merged
      end

      private def keep_comment_with_following?(
        current : RangeSection,
        next_section : RangeSection,
        following : RangeSection?,
        max_chunk_size : Int32,
      ) : Bool
        return false unless current.node.nil?
        return false unless next_node = next_section.node
        return false unless comment_like?(next_node)
        return false unless following

        comment_and_following_size = following.end_byte - next_section.start_byte
        whole_size = following.end_byte - current.start_byte

        comment_and_following_size <= max_chunk_size &&
          whole_size > max_chunk_size
      end

      private def fallback_ranges(source : String, start_byte : Int32, end_byte : Int32, max_chunk_size : Int32) : Array(RangeSection)
        ranges = [] of RangeSection
        cursor = start_byte

        while cursor < end_byte
          target_end = Math.min(cursor + max_chunk_size, end_byte)
          split_end = newline_split_end(source, cursor, target_end, end_byte)
          split_end = utf8_safe_end(source, cursor, split_end)
          split_end = utf8_safe_end(source, cursor, target_end) if split_end <= cursor
          split_end = end_byte if split_end <= cursor

          ranges << RangeSection.new(start_byte: cursor, end_byte: split_end)
          cursor = split_end
        end

        ranges
      end

      private def newline_split_end(source : String, start_byte : Int32, target_end : Int32, limit_end : Int32) : Int32
        slice = slice_bytes(source, start_byte, target_end)
        newline_index = slice.rindex('\n')
        return target_end unless newline_index

        split_end = start_byte + newline_index + 1
        split_end < limit_end ? split_end : target_end
      end

      private def utf8_safe_end(source : String, start_byte : Int32, target_end : Int32) : Int32
        end_byte = target_end
        while end_byte > start_byte
          candidate = slice_bytes(source, start_byte, end_byte)
          return end_byte if candidate.valid_encoding?
          end_byte -= 1
        end
        start_byte
      end

      private def collect_chunk_context(
        root : TreeSitter::Node,
        source : String,
        language : String,
        start_byte : Int32,
        end_byte : Int32,
        chunk_index : Int32,
        total_chunks : Int32,
      ) : ChunkContext
        node_types = Set(String).new
        symbols_defined = [] of String
        comments = [] of CommentInfo
        leading_comment_candidates = [] of CommentInfo
        definitions = [] of Tuple(String, Span)
        has_error_nodes = false

        walk_nodes(root) do |node, depth|
          overlaps_chunk = node.end_byte.to_i32 > start_byte && node.start_byte.to_i32 < end_byte

          if !overlaps_chunk
            if comment_like?(node) && node.end_byte.to_i32 <= start_byte
              gap = slice_bytes(source, node.end_byte.to_i32, start_byte)
              if gap.strip.empty?
                leading_comment_candidates << CommentInfo.new(
                  text: normalize_comment_text(node.text(source)),
                  span: Span.from_node(node),
                )
              end
            end
            next
          end

          has_error_nodes ||= node.has_error? || node.missing?

          if depth <= 1 && node.named? && fully_inside?(node, start_byte, end_byte)
            node_types << node.type
          end

          if comment_like?(node) && fully_inside?(node, start_byte, end_byte)
            comments << CommentInfo.new(
              text: normalize_comment_text(node.text(source)),
              span: Span.from_node(node),
            )
          end

          next unless definition_like?(node)
          next unless name = definition_name(node, source)

          if fully_inside?(node, start_byte, end_byte)
            symbols_defined << name
            definitions << {name, Span.from_node(node)}
          end
        end

        context_path = enclosing_context_path(root, source, start_byte)
        candidate = leading_comment_candidates.max_by?(&.span.end_byte)
        if comments.empty? && candidate
          comments << candidate
        end
        docstrings = collect_docstrings(comments, definitions)

        ChunkContext.new(
          language: language,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          node_types: node_types.to_a.sort,
          context_path: context_path,
          symbols_defined: symbols_defined.uniq,
          comments: comments,
          docstrings: docstrings,
          has_error_nodes: has_error_nodes,
        )
      end

      private def enclosing_context_path(root : TreeSitter::Node, source : String, chunk_start_byte : Int32) : Array(String)
        target = root.descendant(chunk_start_byte.to_u32, chunk_start_byte.to_u32) || root
        path = [] of String
        current = target

        loop do
          if current.start_byte.to_i32 < chunk_start_byte && definition_like?(current)
            if name = definition_name(current, source)
              path << name
            end
          end

          parent = current.parent
          break unless parent
          current = parent
        end

        reversed = path.reverse
        reversed.uniq!
        reversed
      end

      private def collect_docstrings(
        comments : Array(CommentInfo),
        definitions : Array(Tuple(String, Span)),
      ) : Array(DocstringInfo)
        docstrings = [] of DocstringInfo

        comments.each do |comment|
          next unless definitions.any? do |(_, span)|
                        span.start_line - comment.span.end_line <= 1 && span.start_line >= comment.span.end_line
                      end

          docstrings << DocstringInfo.new(text: comment.text, span: comment.span)
        end

        docstrings
      end

      private def walk_nodes(node : TreeSitter::Node, &block : TreeSitter::Node, Int32 ->) : Nil
        stack = [{node, 0}] of Tuple(TreeSitter::Node, Int32)

        until stack.empty?
          current, depth = stack.pop
          block.call(current, depth)

          children = current.children.to_a
          (children.size - 1).downto(0) do |index|
            stack << {children[index], depth + 1}
          end
        end
      end

      private def fully_inside?(node : TreeSitter::Node, start_byte : Int32, end_byte : Int32) : Bool
        node.start_byte.to_i32 >= start_byte && node.end_byte.to_i32 <= end_byte
      end

      private def definition_like?(node : TreeSitter::Node) : Bool
        type = node.type
        return true if DEF_LIKE_TYPES.includes?(type)
        return true if type.ends_with?("_definition")
        return true if type.ends_with?("_declaration")
        false
      end

      private def comment_like?(node : TreeSitter::Node) : Bool
        type = node.type
        COMMENT_LIKE_TYPES.includes?(type) || type.includes?("comment")
      end

      private def definition_name(node : TreeSitter::Node, source : String) : String?
        if name_node = node.child_by_field_name("name")
          name = definition_name_token(name_node, source)
          return name if name
        end

        if node.type.in?("method_def", "abstract_method_def")
          name, _ = crystal_style_method_signature(node, source)
          return name if name
        end

        node.children.each do |child|
          next unless child.named?
          name = definition_name_token(child, source)
          return name if name
        end

        nil
      end

      private def definition_name_token(node : TreeSitter::Node, source : String) : String?
        text = node.text(source).strip
        return text if node.type.in?("constant", "identifier") && !text.empty? && !text.includes?('\n')

        node.children.each do |child|
          next unless child.named?
          name = definition_name_token(child, source)
          return name if name
        end

        nil
      end

      private def crystal_style_method_signature(node : TreeSitter::Node, source : String) : {String?, Bool}
        name = nil.as(String?)
        is_class_method = false
        found_self = false
        found_dot = false

        node.children.each do |child|
          case child.type
          when "identifier"
            if name.nil? && !found_self
              name = child.text(source)
            elsif name.nil? && found_self && found_dot
              name = child.text(source)
              is_class_method = true
            end
          when "self"
            found_self = true
          when "."
            found_dot = true
          end
        end

        {name, is_class_method}
      end

      private def normalize_comment_text(text : String) : String
        text.lines.map do |line|
          line.lstrip.sub(/^#\s?/, "").sub(%r{^//\s?}, "").sub(%r{^/\*\s?}, "").sub(%r{\s?\*/$}, "").rstrip
        end.join("\n").strip
      end

      private def slice_bytes(source : String, start_byte : Int32, end_byte : Int32) : String
        source.byte_slice(start_byte, end_byte - start_byte) || ""
      end

      private def span_for_range(source : String, start_byte : Int32, end_byte : Int32) : Span
        start_line, start_column = line_and_column_for_byte(source, start_byte)
        end_line, end_column = line_and_column_for_byte(source, end_byte)
        Span.new(
          start_byte: start_byte,
          end_byte: end_byte,
          start_line: start_line,
          start_column: start_column,
          end_line: end_line,
          end_column: end_column,
        )
      end

      private def line_and_column_for_byte(source : String, byte_index : Int32) : {Int32, Int32}
        prefix = source.byte_slice(0, byte_index) || ""
        last_newline = prefix.rindex('\n')
        line = prefix.count('\n').to_i32 + 1
        column = if last_newline
                   prefix.bytesize - last_newline - 1
                 else
                   prefix.bytesize
                 end
        {line, column.to_i32}
      end
    end
  end
end
