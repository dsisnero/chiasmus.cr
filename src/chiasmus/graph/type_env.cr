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

        (0...declarator_node.named_child_count).each do |i|
          child = declarator_node.named_child(i)
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

        (0...body_node.named_child_count).each do |i|
          child = body_node.named_child(i)
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
            c = child.named_child(j)
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
            (0...params.named_child_count).each do |k|
              param = params.named_child(k)
              if param && param.type == "required_parameter"
                has_modifier = false
                (0...param.named_child_count).each do |m|
                  mc = param.named_child(m)
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
          gc = child.named_child(g)
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
          c = child.named_child(j)
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

        (0...body_node.named_child_count).each do |i|
          child = body_node.named_child(i)
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

        # class Child extends Parent — tree-sitter typescript uses class_heritage > extends_clause
        # Try both field-name access and child-type scanning
        if parent_node = class_node.child_by_field_name("parent")
          parent_name = parent_node.text(source).strip
          entries << ClassExtendsEntry.new(class_name: class_name, parent: parent_name) unless parent_name.empty?
        end

        # extends_type_clause for interfaces, and class_heritage scanning
        (0...class_node.named_child_count).each do |i|
          child = class_node.named_child(i)
          next unless child
          case child.type
          when "class_heritage"
            # class_heritage contains extends_clause children
            (0...child.named_child_count).each do |j|
              ec = child.named_child(j)
              next unless ec
              if ec.type == "extends_clause"
                # Scan extends_clause children for type identifiers
                (0...ec.named_child_count).each do |k|
                  tc = ec.named_child(k)
                  next unless tc
                  if tc.type == "identifier" || tc.type == "type_identifier" || tc.type == "nested_type_identifier"
                    parent_name = tc.text(source).strip
                    entries << ClassExtendsEntry.new(class_name: class_name, parent: parent_name) unless parent_name.empty?
                  end
                end
              end
            end
          when "extends_type_clause"
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

        collect_node_info(root_node, source, class_fields_entries, class_methods_entries, class_extends_entries)

        FileTypeInfo.new(
          file: file,
          class_fields: class_fields_entries,
          class_methods: class_methods_entries.empty? ? nil : class_methods_entries,
          class_extends: class_extends_entries.empty? ? nil : class_extends_entries,
        )
      end

      private def collect_node_info(
        node : TreeSitter::Node,
        source : String,
        class_fields_entries : Array(ClassFieldEntry),
        class_methods_entries : Array(ClassMethodEntry),
        class_extends_entries : Array(ClassExtendsEntry),
      ) : Nil
        if CLASS_NODE_TYPES.includes?(node.type)
          name_node = node.child_by_field_name("name")
          if name_node
            class_name = name_node.text(source)
            unless class_name.empty?
              fields = extract_class_fields(node, source)
              methods = extract_class_method_names(node, source)
              extends = extract_class_extends(node, source)

              class_fields_entries << ClassFieldEntry.new(class_name: class_name, fields: fields) unless fields.empty?
              class_methods_entries << ClassMethodEntry.new(class_name: class_name, methods: methods) unless methods.empty?
              class_extends_entries.concat(extends)
            end
          end
        end

        return if node.named_child_count == 0
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          collect_node_info(child, source, class_fields_entries, class_methods_entries, class_extends_entries)
        end
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
