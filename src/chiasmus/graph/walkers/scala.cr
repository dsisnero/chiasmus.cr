require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_scala(
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
        return if handle_scala_declaration(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_scala_call(node, source, scope_stack, calls, call_set)
        handle_scala_import(node, source, file_path, imports)

        walk_scala_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_scala_declaration(
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
        when "class_definition"
          name = scala_identifier_child(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_scala_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "object_definition"
          name = scala_identifier_child(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          true
        when "trait_definition"
          name = scala_identifier_child(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          true
        when "function_definition"
          name = scala_identifier_child(node, source)
          return false unless name
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_scala_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "val_definition", "var_definition"
          name = scala_val_pattern(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Variable, line: node.start_point.row.to_i + 1)
          true
        else
          false
        end
      end

      private def scala_identifier_child(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return name.text(source) if name

        scala_find_child(node, "identifier").try(&.text(source))
      end

      private def scala_val_pattern(node : TreeSitter::Node, source : String) : String?
        pattern = node.child_by_field_name("pattern")
        return pattern.text(source) if pattern

        scala_find_child(node, "identifier").try(&.text(source))
      end

      private def scala_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def handle_scala_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call_expression"

        func = node.child_by_field_name("function") || scala_find_child(node, "identifier")
        return unless func
        record_call(scope_stack.last?, func.text(source), calls, call_set)
      end

      private def handle_scala_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "import_declaration"

        import_text = node.text(source).gsub(/^import\s+/, "").strip
        imports << ImportsFact.new(file: file_path, name: import_text, source: import_text)
      end

      private def walk_scala_children(
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
          walk_scala(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
