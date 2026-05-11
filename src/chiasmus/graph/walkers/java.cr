require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_java(
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
        return if handle_java_scope(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_java_call(node, source, scope_stack, calls, call_set)
        return if handle_java_import(node, source, file_path, imports)

        walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_java_scope(
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
        when "method_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          kind = java_in_class?(node) ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          if class_name = java_enclosing_class(node, source)
            contains << ContainsFact.new(parent: class_name, child: name)
          end
          with_scope(scope_stack, name) do
            walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "class_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "interface_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "enum_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "record_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_java_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def handle_java_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "method_invocation"

        callee = resolve_java_callee(node, source)
        record_call(scope_stack.last?, callee, calls, call_set)
      end

      private def handle_java_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_declaration"

        scoped = node.children.find(&.type.==("scoped_identifier"))
        return true unless scoped

        name_node = scoped.child_by_field_name("name")
        name = name_node.try(&.text(source)) || scoped.text(source)
        imports << ImportsFact.new(file: file_path, name: name, source: scoped.text(source))
        true
      end

      private def walk_java_children(
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
          walk_java(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def java_in_class?(node : TreeSitter::Node) : Bool
        current = node.parent
        while current
          t = current.type
          return true if t == "class_body"
          return true if t == "interface_body"
          return true if t == "enum_body"
          current = current.parent
        end
        false
      end

      private def java_enclosing_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          t = current.type
          if t == "class_declaration" || t == "interface_declaration" || t == "enum_declaration" || t == "record_declaration"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          end
          if t == "class_body" || t == "interface_body" || t == "enum_body"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end

      private def resolve_java_callee(call_node : TreeSitter::Node, source : String) : String?
        name_node = call_node.child_by_field_name("name")
        return name_node.text(source) if name_node

        call_node.children.each do |child|
          if child.type == "identifier"
            return child.text(source)
          end
        end
        nil
      end
    end
  end
end
