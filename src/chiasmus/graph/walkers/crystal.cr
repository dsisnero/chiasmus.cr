require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_crystal(
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
        return if handle_crystal_scope(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        return if handle_crystal_call(node, source, file_path, scope_stack, calls, imports, call_set)
        handle_crystal_identifier_call(node, source, scope_stack, calls, call_set)
        return if handle_crystal_require(node, source, file_path, imports)

        walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_crystal_scope(
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
        when "method_def", "abstract_method_def"
          crystal_method_name, is_class_method = crystal_method_signature(node, source)
          return false unless crystal_method_name

          kind = is_class_method ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: crystal_method_name, kind: kind, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: crystal_method_name)
          end
          with_scope(scope_stack, crystal_method_name) do
            walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "class_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "struct_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "module_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Interface, defines, calls, imports, exports, contains, call_set)
        when "alias"
          crystal_alias_scope(node, source, file_path, defines)
        else
          false
        end
      end

      private def crystal_alias_scope(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
      ) : Bool
        name = node.children.find(&.type.==("constant")).try(&.text(source))
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, line: node.start_point.row.to_i + 1)
        true
      end

      private def crystal_container_scope(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        kind : SymbolKind,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        name = node.children.find(&.type.==("constant")).try(&.text(source))
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
        with_scope(scope_stack, name) do
          walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
        true
      end

      private def crystal_method_signature(node : TreeSitter::Node, source : String) : {String?, Bool}
        name = nil
        is_class_method = false
        found_self = false
        found_dot = false

        node.children.each do |child|
          case child.type
          when "identifier"
            if name.nil? && !found_self
              name = child.text(source)
            elsif name.nil? && found_self && found_dot
              name = child.text(source)
              is_class_method = true
            end
          when "self"
            found_self = true
          when "."
            found_dot = true
          end
        end

        {name, is_class_method}
      end

      private def handle_crystal_call(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        call_set : Set(String),
      ) : Bool
        return false unless node.type == "call"

        callee = resolve_crystal_callee(node, source)
        if callee == "require_relative"
          crystal_require_relative_imports(node, source, file_path, imports)
          return true
        end

        record_call(scope_stack.last?, callee, calls, call_set)
        false
      end

      private def crystal_require_relative_imports(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        node.children.each do |child|
          next unless child.type == "argument_list"

          child.children.each do |arg|
            next unless arg.type == "string"

            source_name = extract_string_content(arg, source)
            imports << ImportsFact.new(file: file_path, name: source_name, source: source_name) if source_name
          end
        end
      end

      private def handle_crystal_identifier_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "identifier"
        return unless scope_stack.last?

        parent = node.parent
        return unless parent
        return if parent.type == "method_def" || parent.type == "abstract_method_def"
        return if parent.type == "parameters"

        text = node.text(source)
        record_call(scope_stack.last?, text, calls, call_set)
      end

      private def handle_crystal_require(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "require"

        node.children.each do |child|
          next unless child.type == "string"

          source_name = extract_string_content(child, source)
          next unless source_name

          imports << ImportsFact.new(file: file_path, name: File.basename(source_name, ".cr"), source: source_name)
          return true
        end

        true
      end

      private def walk_crystal_children(
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
          walk_crystal(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def resolve_crystal_callee(call_node : TreeSitter::Node, source : String) : String?
        method_node = call_node.child_by_field_name("method")
        return method_node.text(source) if method_node

        call_node.children.each do |child|
          if child.type == "identifier"
            return child.text(source)
          end
        end

        nil
      end

      private def find_crystal_enclosing_class(node : TreeSitter::Node, source : String) : String?
        nil
      end
    end
  end
end
