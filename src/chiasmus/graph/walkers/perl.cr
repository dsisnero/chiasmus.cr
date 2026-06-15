require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_perl(
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
        return if handle_perl_declaration(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_perl_call(node, source, scope_stack, calls, call_set)
        handle_perl_use(node, source, file_path, imports)

        walk_perl_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_perl_declaration(
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
        when "subroutine_declaration_statement"
          name_node = perl_find_child(node, "bareword")
          return false unless name_node
          name = name_node.text(source)
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1, end_line: node.end_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          with_scope(scope_stack, name) do
            walk_perl_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def perl_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def handle_perl_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        case node.type
        when "method_call_expression"
          method_node = perl_find_child(node, "method")
          return unless method_node
          record_call(scope_stack.last?, method_node.text(source), calls, call_set)
        when "ambiguous_function_call_expression"
          func_node = perl_find_child(node, "function")
          return unless func_node
          record_call(scope_stack.last?, func_node.text(source), calls, call_set)
        end
      end

      private def handle_perl_use(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "use_statement"

        pkg_node = perl_find_child(node, "package")
        return unless pkg_node

        imports << ImportsFact.new(file: file_path, name: pkg_node.text(source), source: pkg_node.text(source))
      end

      private def walk_perl_children(
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
          walk_perl(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
