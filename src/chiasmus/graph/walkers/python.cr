require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_python(
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
        return if handle_python_scope(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_python_call(node, source, scope_stack, calls, call_set)
        return if handle_python_import(node, source, file_path, imports)
        return if handle_python_import_from(node, source, file_path, imports)

        walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_python_scope(
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
        when "function_definition"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          enclosing_class = find_python_enclosing_class(node, source)
          kind = enclosing_class ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          contains << ContainsFact.new(parent: enclosing_class, child: name) if enclosing_class
          with_scope(scope_stack, name) do
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "class_definition"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def handle_python_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call"

        record_call(scope_stack.last?, resolve_python_callee(node, source), calls, call_set)
      end

      private def handle_python_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_statement"

        node.children.each do |child|
          case child.type
          when "dotted_name"
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: child.text(source))
          when "aliased_import"
            append_python_aliased_import(child, source, file_path, imports, nil)
          end
        end

        true
      end

      private def handle_python_import_from(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_from_statement"

        module_node = node.child_by_field_name("module_name")
        source_name = module_node.try(&.text(source)) || ""
        name_node = node.child_by_field_name("name")
        append_python_direct_import(name_node, source, file_path, imports, source_name) if name_node

        node.children.each do |child|
          if child.type == "dotted_name" && child != module_node && child != name_node
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: source_name)
          elsif child.type == "aliased_import"
            append_python_aliased_import(child, source, file_path, imports, source_name)
          end
        end

        true
      end

      private def append_python_direct_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        source_name : String,
      ) : Nil
        return unless node.type == "dotted_name" || node.type == "identifier"

        imports << ImportsFact.new(file: file_path, name: node.text(source), source: source_name)
      end

      private def append_python_aliased_import(
        child : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        import_source : String?,
      ) : Nil
        dotted = child.child_by_field_name("name")
        return unless dotted

        alias_node = child.child_by_field_name("alias")
        alias_name = alias_node ? alias_node.text(source) : dotted.text(source)
        imports << ImportsFact.new(file: file_path, name: alias_name, source: import_source || dotted.text(source))
      end

      private def walk_python_children(
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
          walk_python(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def resolve_python_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "attribute"
          attr = fn_node.child_by_field_name("attribute")
          attr.try(&.text(source))
        else
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      private def find_python_enclosing_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          type = current.type
          if type == "class_definition"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          end
          if type == "block"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end
    end
  end
end
