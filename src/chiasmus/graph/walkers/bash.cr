require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_bash(
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
        if node.type == "function_definition"
          handle_bash_function(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        else
          handle_bash_command(node, source, scope_stack, calls, call_set)
          walk_bash_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def handle_bash_function(
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
        name = node.child_by_field_name("name") || node.named_child(0)
        return unless name

        func_name = name.text(source)
        defines << DefinesFact.new(file: file_path, name: func_name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1, end_line: node.end_point.row.to_i + 1)
        with_scope(scope_stack, func_name) do
          walk_bash_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def handle_bash_command(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "command"

        # Find command_name child
        cmd_name = nil
        (0...node.named_child_count).each do |child_idx|
          child = node.named_child(child_idx)
          next unless child
          if child.type == "command_name"
            cmd_name = child.text(source)
            break
          end
        end
        return unless cmd_name

        record_call(scope_stack.last?, cmd_name, calls, call_set)
      end

      private def walk_bash_children(
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
          walk_bash(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
