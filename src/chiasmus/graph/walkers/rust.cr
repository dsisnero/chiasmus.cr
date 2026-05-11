require "../types"

module Chiasmus
  module Graph
    module Walkers
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
      ) : Nil
        return if handle_rust_scope(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_rust_call(node, source, scope_stack, calls, call_set)
        return if handle_rust_use(node, source, file_path, imports)

        walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_rust_scope(
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
      ) : Bool
        case node.type
        when "function_item"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          kind = rust_in_impl?(node) ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          if kind == SymbolKind::Method
            if impl_type = rust_enclosing_impl_type(node, source)
              contains << ContainsFact.new(parent: impl_type, child: name)
            end
          end
          with_scope(scope_stack, name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "struct_item"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "enum_item"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "trait_item"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "impl_item"
          type_node = node.child_by_field_name("type")
          type_name = type_node.try(&.text(source))
          return false unless type_name

          defines << DefinesFact.new(file: file_path, name: type_name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, type_name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "mod_item"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_rust_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def rust_in_impl?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          return true if current.type == "impl_item"
          current = current.parent
        end
        false
      end

      private def rust_enclosing_impl_type(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          if current.type == "impl_item"
            type_node = current.child_by_field_name("type")
            return type_node.try(&.text(source))
          end
          current = current.parent
        end
        nil
      end

      private def handle_rust_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call_expression"

        callee = resolve_rust_callee(node, source)
        record_call(scope_stack.last?, callee, calls, call_set)
      end

      private def handle_rust_use(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "use_declaration"

        extract_rust_use_paths(node, source, file_path, imports)
        true
      end

      private def extract_rust_use_paths(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        node.children.each do |child|
          case child.type
          when "scoped_identifier"
            name = child.child_by_field_name("name").try(&.text(source)) || child.text(source)
            full_path = child.text(source)
            imports << ImportsFact.new(file: file_path, name: name, source: full_path)
          when "identifier"
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: child.text(source))
          when "use_as_clause"
            name_node = child.child_by_field_name("name").try(&.text(source))
            alias_node = child.child_by_field_name("alias")
            if alias_node
              alias_name = alias_node.children.find(&.type.==("identifier")).try(&.text(source))
              if alias_name && name_node
                imports << ImportsFact.new(file: file_path, name: alias_name, source: name_node)
              end
            end
          end
        end
      end

      private def walk_rust_children(
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
      ) : Nil
        node.children.each do |child|
          walk_rust(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def resolve_rust_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "field_expression"
          value = fn_node.child_by_field_name("value")
          field = fn_node.child_by_field_name("field")
          if field
            field.text(source)
          elsif value
            value.text(source)
          else
            nil
          end
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
    end
  end
end
