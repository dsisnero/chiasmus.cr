require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_kotlin(
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
        return if handle_kotlin_declaration(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_kotlin_call(node, source, scope_stack, calls, call_set)
        handle_kotlin_import(node, source, file_path, imports)

        walk_kotlin_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_kotlin_declaration(
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
          name = kotlin_class_name(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_kotlin_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "function_declaration"
          name = kotlin_find_child(node, "simple_identifier").try(&.text(source))
          return false unless name
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_kotlin_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def kotlin_class_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return name.text(source) if name
        kotlin_find_child(node, "type_identifier").try(&.text(source))
      end

      private def kotlin_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def handle_kotlin_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call_expression"

        si = kotlin_find_child(node, "simple_identifier")
        return unless si

        record_call(scope_stack.last?, si.text(source), calls, call_set)
      end

      private def handle_kotlin_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "import_header"

        import_text = node.text(source).gsub(/^import\s+/, "").strip
        imports << ImportsFact.new(file: file_path, name: import_text, source: import_text)
      end

      private def walk_kotlin_children(
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
          walk_kotlin(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
