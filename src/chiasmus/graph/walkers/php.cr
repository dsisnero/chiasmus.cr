require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_php(
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
        return if handle_php_declaration(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_php_call(node, source, scope_stack, calls, call_set)
        handle_php_use(node, source, file_path, imports)

        walk_php_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_php_declaration(
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
        when "class_declaration"
          name = php_declaration_name(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_php_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "method_declaration"
          name = php_declaration_name(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_php_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "function_definition"
          name = php_declaration_name(node, source)
          return false unless name
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_php_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def php_declaration_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return name.text(source) if name

        php_find_child(node, "name").try(&.text(source))
      end

      private def php_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def handle_php_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "function_call_expression"

        func = node.child_by_field_name("function") || php_find_child(node, "name")
        return unless func

        record_call(scope_stack.last?, func.text(source), calls, call_set)
      end

      private def handle_php_use(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "namespace_use_clause"

        qualified = php_find_child(node, "qualified_name")
        if qualified
          import_name = qualified.text(source)
          name_part = import_name.split("\\").last? || import_name
          imports << ImportsFact.new(file: file_path, name: name_part, source: import_name)
          return
        end

        import_name = node.text(source).strip
        name_part = import_name.split("\\").last? || import_name
        imports << ImportsFact.new(file: file_path, name: name_part, source: import_name)
      end

      private def walk_php_children(
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
          walk_php(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
