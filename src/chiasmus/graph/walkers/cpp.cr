require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_cpp(
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
        return if handle_cpp_declaration(node, source, file_path, scope_stack, defines, calls, contains, call_set)
        handle_cpp_call(node, source, scope_stack, calls, call_set)
        handle_cpp_include(node, source, file_path, imports)

        walk_cpp_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_cpp_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        case node.type
        when "class_specifier", "struct_specifier"
          name = cpp_declaration_name(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1, end_line: node.end_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
          end
          true
        when "function_definition"
          name = cpp_function_name(node, source)
          return false unless name
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1, end_line: node.end_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
          end
          true
        when "field_declaration"
          # Class method declarations (field_declaration with function_declarator)
          cpp_handle_field_declaration(node, source, file_path, scope_stack, defines, contains)
        else
          false
        end
      end

      private def cpp_handle_field_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        declarator = node.child_by_field_name("declarator")
        return false unless declarator
        return false unless declarator.type == "function_declarator"

        mname = nil
        (0...declarator.named_child_count).each do |child_idx|
          child = declarator.named_child(child_idx)
          next unless child
          if child.type.in?("identifier", "field_identifier")
            mname = child.text(source)
            break
          end
        end
        return false unless mname

        defines << DefinesFact.new(file: file_path, name: mname, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1, end_line: node.end_point.row.to_i + 1)
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: mname)
        end
        true
      end

      private def cpp_declaration_name(node : TreeSitter::Node, source : String) : String?
        node.child_by_field_name("name").try(&.text(source))
      end

      private def cpp_function_name(node : TreeSitter::Node, source : String) : String?
        declarator = node.child_by_field_name("declarator")
        return nil unless declarator
        (0...declarator.named_child_count).each do |child_idx|
          child = declarator.named_child(child_idx)
          next unless child
          if child.type.in?("identifier", "field_identifier")
            return child.text(source)
          end
        end
        nil
      end

      private def cpp_namespace_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return nil unless name
        name.text(source)
      end

      private def handle_cpp_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call_expression"

        callee = resolve_cpp_callee(node, source)
        return unless callee
        record_call(scope_stack.last?, callee, calls, call_set)
      end

      private def resolve_cpp_callee(call_node : TreeSitter::Node, source : String) : String?
        func = call_node.child_by_field_name("function")
        return nil unless func
        if func.type == "field_expression"
          field = func.child_by_field_name("field")
          return field.text(source) if field
        end
        func.text(source)
      end

      private def handle_cpp_include(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "preproc_include"

        path_node = node.child_by_field_name("path")
        unless path_node
          (0...node.named_child_count).each do |child_idx|
            child = node.named_child(child_idx)
            next unless child
            if child.type.in?("system_lib_string", "string_literal")
              path_node = child
              break
            end
          end
        end
        return unless path_node

        import_name = path_node.text(source).gsub(/[<>"]/, "")
        imports << ImportsFact.new(file: file_path, name: import_name, source: import_name)
      end

      private def walk_cpp_children(
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
          walk_cpp(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
