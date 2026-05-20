# Ported from vendor/chiasmus/src/graph/type-env.ts (MIT, pi-code-graph)
#
# Per-file type environment helpers for TypeScript/JavaScript.
# Extracts class field types, method names, and extends relationships
# from tree-sitter AST nodes to feed the project-wide QN resolver.

require "tree_sitter"
require "./types"

module Chiasmus
  module Graph
    module TypeEnv
      extend self

      # --- Type name extraction ---

      def strip_nullable(type_text : String) : String
        t = type_text.strip
        t = t.gsub(/^\|+|\|+$/, "").strip
        if t.includes?('|')
          parts = t.split('|').map(&.strip).reject { |p| p.in?("null", "undefined", "void") }
          t = parts.first? || t
        end
        t = t.gsub(/\?$/, "").strip
        t
      end

      def extract_simple_type_name(type_node : TreeSitter::Node, source : String) : String?
        text = type_node.text(source)
        return nil if text.empty?

        stripped = strip_nullable(text)

        # Reject collections
        return nil if stripped.ends_with?("[]")
        return nil if stripped =~ /^(?:Array|Promise|Map|Set|Record)<.+>$/

        # Unwrap identity-like wrappers
        if m = stripped.match(/^(?:Readonly|Partial)<(.+)>$/)
          stripped = strip_nullable(m[1])
        end

        # Drop generic args: Foo<X> → Foo
        stripped = stripped.sub(/<.*$/, "").strip

        return stripped if stripped =~ /^[A-Za-z_$][A-Za-z0-9_$]*$/
        nil
      end

      # --- Variable annotation extraction ---

      def extract_var_annotation(declarator_node : TreeSitter::Node, source : String) : String?
        if type_node = declarator_node.child_by_field_name("type")
          inner = type_node.child_by_field_name("type") || type_node.named_child(0)
          return extract_simple_type_name(inner, source) if inner
        end

        (0...declarator_node.child_count).each do |i|
          child = declarator_node.child(i)
          next unless child
          if child.type == "type_annotation"
            inner = child.named_child(0)
            return extract_simple_type_name(inner, source) if inner
          end
        end

        nil
      end

      # --- New expression type extraction ---

      def extract_new_expression_type(value_node : TreeSitter::Node, source : String) : String?
        return nil unless value_node.type == "new_expression"

        if ctor_node = value_node.child_by_field_name("constructor")
          return extract_simple_type_name(ctor_node, source)
        end

        first_child = value_node.named_child(0)
        return extract_simple_type_name(first_child, source) if first_child

        nil
      end

      # --- Variable name extraction ---

      def extract_var_name(declarator_node : TreeSitter::Node, source : String) : String?
        name_node = declarator_node.child_by_field_name("name")
        return nil unless name_node
        return nil unless name_node.type == "identifier"
        name_node.text(source)
      end

      # --- Class field extraction ---

      def extract_class_fields(class_node : TreeSitter::Node, source : String) : Hash(String, String)
        fields = Hash(String, String).new
        body_node = class_node.child_by_field_name("body")
        return fields unless body_node

        (0...body_node.child_count).each do |i|
          child = body_node.child(i)
          next unless child

          case child.type
          when "public_field_definition", "field_definition"
            process_field_definition(child, source, fields)
          when "method_definition"
            process_method_definition(child, source, fields)
          when "property_signature"
            process_property_signature(child, source, fields)
          end
        end

        fields
      end

      private def process_field_definition(child : TreeSitter::Node, source : String, fields : Hash(String, String)) : Nil
        name_node = child.child_by_field_name("name")
        return unless name_node
        field_name = name_node.text(source)
        return if field_name.empty?

        field_type : String? = nil

        # Check type annotation
        if type_node = child.child_by_field_name("type")
          inner = type_node.named_child(0) || type_node
          field_type = extract_simple_type_name(inner, source)
        end

        # Fallback: scan children for type_annotation
        unless field_type
          (0...child.child_count).each do |j|
            c = child.child(j)
            if c && c.type == "type_annotation"
              inner = c.named_child(0)
              if inner
                field_type = extract_simple_type_name(inner, source)
                break
              end
            end
          end
        end

        # Fallback: new expression value
        unless field_type
          if value_node = child.child_by_field_name("value")
            field_type = extract_new_expression_type(value_node, source)
          end
        end

        fields[field_name] = field_type if field_type
      end

      private def process_method_definition(child : TreeSitter::Node, source : String, fields : Hash(String, String)) : Nil
        method_name_node = child.child_by_field_name("name")
        return unless method_name_node
        method_name = method_name_node.text(source)
        return if method_name.empty?

        # Constructor parameter properties
        if method_name == "constructor"
          params = child.child_by_field_name("parameters")
          if params
            (0...params.child_count).each do |k|
              param = params.child(k)
              if param && param.type == "required_parameter"
                has_modifier = false
                (0...param.child_count).each do |m|
                  mc = param.child(m)
                  if mc && (mc.type == "accessibility_modifier" || mc.text(source) == "readonly")
                    has_modifier = true
                    break
                  end
                end
                if has_modifier
                  p_name_node = param.child_by_field_name("pattern") || param.named_child(0)
                  if p_name_node
                    param_name = p_name_node.text(source)
                    param_type = extract_var_annotation(param, source)
                    fields[param_name] = param_type if param_name && param_type
                  end
                end
              end
            end
          end
        end

        # Getter return type → field
        is_getter = false
        (0...child.child_count).each do |g|
          gc = child.child(g)
          if gc && gc.type == "get"
            is_getter = true
            break
          end
        end

        if is_getter
          return_type_node = child.child_by_field_name("return_type")
          if return_type_node
            inner = return_type_node.named_child(0) || return_type_node
            return_type = extract_simple_type_name(inner, source)
            fields[method_name] = return_type if return_type
          end
        end
      end

      private def process_property_signature(child : TreeSitter::Node, source : String, fields : Hash(String, String)) : Nil
        name_node = child.child_by_field_name("name")
        return unless name_node
        field_name = name_node.text(source)
        return if field_name.empty?

        (0...child.child_count).each do |j|
          c = child.child(j)
          if c && c.type == "type_annotation"
            inner = c.named_child(0)
            if inner
              field_type = extract_simple_type_name(inner, source)
              fields[field_name] = field_type if field_type
              break
            end
          end
        end
      end

      # --- Class method name collection ---

      def extract_class_method_names(class_node : TreeSitter::Node, source : String) : Array(String)
        methods = [] of String
        body_node = class_node.child_by_field_name("body")
        return methods unless body_node

        (0...body_node.child_count).each do |i|
          child = body_node.child(i)
          next unless child

          case child.type
          when "method_definition"
            name_node = child.child_by_field_name("name")
            if name_node
              mname = name_node.text(source)
              methods << mname unless mname.empty? || mname == "constructor"
            end
          when "method_signature"
            name_node = child.child_by_field_name("name")
            if name_node
              mname = name_node.text(source)
              methods << mname unless mname.empty?
            end
          end
        end

        methods
      end

      # --- Class extends extraction ---

      CLASS_NODE_TYPES = Set{"class_declaration", "class", "abstract_class_declaration", "interface_declaration"}

      def extract_class_extends(class_node : TreeSitter::Node, source : String) : Array(ClassExtendsEntry)
        entries = [] of ClassExtendsEntry
        class_name_node = class_node.child_by_field_name("name")
        return entries unless class_name_node
        class_name = class_name_node.text(source)
        return entries if class_name.empty?

        # class Child extends Parent
        if parent_node = class_node.child_by_field_name("parent") || class_node.child_by_field_name("extends")
          parent_name = extract_simple_type_name(parent_node, source) || parent_node.text(source)
          entries << ClassExtendsEntry.new(class_name: class_name, parent: parent_name) unless parent_name.empty?
        end

        # extends_type_clause for interfaces
        (0...class_node.child_count).each do |i|
          child = class_node.child(i)
          next unless child
          if child.type == "extends_type_clause"
            parent_name = child.text(source).strip
            entries << ClassExtendsEntry.new(class_name: class_name, parent: parent_name) unless parent_name.empty?
          end
        end

        entries
      end

      # --- Collect per-file type info ---

      def collect_type_info(root_node : TreeSitter::Node, source : String, file : String) : FileTypeInfo
        class_fields_entries = [] of ClassFieldEntry
        class_methods_entries = [] of ClassMethodEntry
        class_extends_entries = [] of ClassExtendsEntry

        cursor = TreeSitter::TreeCursor.new(root_node)
        stack = [cursor]
        visited = Set(UInt64).new

        while !stack.empty?
          c = stack.pop
          next if c.node.null?
          node_id = c.node.object_id
          next if visited.includes?(node_id)
          visited << node_id

          if CLASS_NODE_TYPES.includes?(c.node.type)
            name_node = c.node.child_by_field_name("name")
            if name_node
              class_name = name_node.text(source)
              unless class_name.empty?
                fields = extract_class_fields(c.node, source)
                methods = extract_class_method_names(c.node, source)
                extends = extract_class_extends(c.node, source)

                class_fields_entries << ClassFieldEntry.new(class_name: class_name, fields: fields) unless fields.empty?
                class_methods_entries << ClassMethodEntry.new(class_name: class_name, methods: methods) unless methods.empty?
                class_extends_entries.concat(extends)
              end
            end
          end

          c.goto_first_child
          stack << TreeSitter::TreeCursor.new(c.node) rescue nil

          if !c.node.null? && c.node != root_node
            tmp = TreeSitter::TreeCursor.new(c.node)
            tmp.goto_next_sibling
            stack << tmp rescue nil
          end

          # Breadth-walk via children
          (0...c.node.child_count).each do |i|
            child = c.node.child(i)
            next if child.null?
            if CLASS_NODE_TYPES.includes?(child.type)
              name_node = child.child_by_field_name("name")
              if name_node
                class_name = name_node.text(source)
                unless class_name.empty?
                  fields = extract_class_fields(child, source)
                  methods = extract_class_method_names(child, source)
                  extends = extract_class_extends(child, source)

                  class_fields_entries << ClassFieldEntry.new(class_name: class_name, fields: fields) unless fields.empty?
                  class_methods_entries << ClassMethodEntry.new(class_name: class_name, methods: methods) unless methods.empty?
                  class_extends_entries.concat(extends)
                end
              end
            end
          end
        end

        FileTypeInfo.new(
          file: file,
          class_fields: class_fields_entries,
          class_methods: class_methods_entries.empty? ? nil : class_methods_entries,
          class_extends: class_extends_entries.empty? ? nil : class_extends_entries,
        )
      end

      # --- Scope helpers ---

      FUNCTION_NODE_TYPES = Set{
        "function_declaration",
        "generator_function_declaration",
        "function_expression",
        "arrow_function",
        "method_definition",
        "function_signature",
      }

      def find_enclosing_class_name(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          if CLASS_NODE_TYPES.includes?(current.type)
            name_node = current.child_by_field_name("name")
            return name_node.text(source) if name_node
          end
          current = current.parent
        end
        nil
      end
    end
  end
end
