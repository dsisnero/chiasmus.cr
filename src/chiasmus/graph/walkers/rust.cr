require "../types"

module Chiasmus
  module Graph
    module Walkers
      # ameba:disable Metrics/CyclomaticComplexity
      def walk_rust(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
        impl_type : String? = nil,
      ) : Nil
        child_count = node.named_child_count.to_i32
        child_count.times do |i|
          child = node.named_child(i)
          next unless child

          case child.type
          when "function_item", "function_signature_item"
            name = child.child_by_field_name("name").try(&.text(source))
            if name
              kind = impl_type ? SymbolKind::Method : SymbolKind::Function
              sig = extract_rust_signature(child, source)
              defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(child), signature: sig)
              if impl_type
                contains << ContainsFact.new(parent: impl_type, child: name)
              end
              if rust_pub?(child)
                exports << ExportsFact.new(file: file_path, name: name)
              end
              with_scope(scope_stack, name) do
                extract_rust_calls(child.child_by_field_name("body"), source, name, calls, call_set)
              end
            end
          when "struct_item", "union_item"
            name = child.child_by_field_name("name").try(&.text(source))
            if name
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(child))
              if rust_pub?(child)
                exports << ExportsFact.new(file: file_path, name: name)
              end
            end
          when "enum_item"
            name = child.child_by_field_name("name").try(&.text(source))
            if name
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(child))
              if rust_pub?(child)
                exports << ExportsFact.new(file: file_path, name: name)
              end
            end
            # Extract enum variants
            (0...child.named_child_count).each do |child_idx|
              variant_child = child.named_child(child_idx)
              next unless variant_child
              next unless variant_child.type == "enum_variant_list"
              (0...variant_child.named_child_count).each do |variant_idx|
                variant = variant_child.named_child(variant_idx)
                next unless variant
                next unless variant.type == "enum_variant"
                variant_name = variant.child_by_field_name("name").try(&.text(source))
                if variant_name
                  defines << DefinesFact.new(file: file_path, name: variant_name, kind: SymbolKind::Type, span: Span.from_node(variant))
                end
              end
            end
          when "trait_item"
            name = child.child_by_field_name("name").try(&.text(source))
            if name
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, span: Span.from_node(child))
              if rust_pub?(child)
                exports << ExportsFact.new(file: file_path, name: name)
              end
              body = child.child_by_field_name("body")
              if body
                walk_rust(body, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set, impl_type: name)
              end
            end
          when "impl_item"
            type_name = child.child_by_field_name("type").try(&.text(source))
            body = child.child_by_field_name("body")
            if body
              walk_rust(body, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set, impl_type: type_name)
            end
          when "mod_item"
            body = child.child_by_field_name("body")
            if body
              walk_rust(body, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
            end
          when "use_declaration"
            extract_rust_use(child, source, file_path, imports)
          end
        end
      end

      private def rust_pub?(node : TreeSitter::Node) : Bool
        count = node.named_child_count.to_i32
        count.times do |i|
          c = node.named_child(i)
          return true if c && c.type == "visibility_modifier"
        end
        false
      end

      private def extract_rust_signature(node : TreeSitter::Node, source : String) : String?
        params = node.child_by_field_name("parameters")
        return nil unless params

        sig = params.text(source)
        ret = node.child_by_field_name("return_type")
        sig += " -> #{ret.text(source)}" if ret
        collapse_signature(sig)
      end

      private def collapse_signature(s : String) : String
        s.gsub(/\s+/, " ").strip
      end

      private def extract_rust_calls(
        node : TreeSitter::Node?,
        source : String,
        caller : String,
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node

        node.children.each do |child|
          if child.type == "call_expression"
            callee = resolve_rust_callee(child, source)
            record_call(caller, callee, calls, call_set)
          end
          extract_rust_calls(child, source, caller, calls, call_set)
        end
      end

      private def resolve_rust_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "field_expression"
          field = fn_node.child_by_field_name("field")
          field.try(&.text(source))
        when "scoped_identifier"
          name = fn_node.child_by_field_name("name")
          name.try(&.text(source))
        when "scoped_type_identifier"
          name = fn_node.child_by_field_name("name")
          name.try(&.text(source))
        else
          nil
        end
      end

      private def extract_rust_use(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        count = node.named_child_count.to_i32
        count.times do |i|
          child = node.named_child(i)
          next unless child
          collect_rust_use(child, "", source, file_path, imports)
        end
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def collect_rust_use(
        node : TreeSitter::Node?,
        prefix : String,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node

        case node.type
        when "identifier", "type_identifier"
          imp_source = prefix.empty? ? node.text(source) : prefix
          imports << ImportsFact.new(file: file_path, name: node.text(source), source: imp_source)
        when "scoped_identifier"
          path = node.child_by_field_name("path").try(&.text(source)) || prefix
          name = node.child_by_field_name("name").try(&.text(source))
          if name
            imports << ImportsFact.new(file: file_path, name: name, source: path.empty? ? name : path)
          end
        when "scoped_use_list"
          path = node.child_by_field_name("path").try(&.text(source)) || prefix
          count = node.named_child_count.to_i32
          count.times do |i|
            child = node.named_child(i)
            next unless child
            if child.type == "use_list"
              list_count = child.named_child_count.to_i32
              list_count.times do |j|
                item = child.named_child(j)
                next unless item
                collect_rust_use(item, path, source, file_path, imports)
              end
            end
          end
        when "use_as_clause"
          alias_node = node.child_by_field_name("alias")
          path_node = node.child_by_field_name("path")
          if alias_node && (alias_name = alias_node.text(source))
            imp_source = prefix.empty? ? (path_node.try(&.text(source)) || alias_name) : prefix
            imports << ImportsFact.new(file: file_path, name: alias_name, source: imp_source)
          end
        when "use_wildcard"
          # use x::* binds no nameable symbol — skip
        end
      end
    end
  end
end
