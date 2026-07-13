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
          handle_cpp_class(node, source, file_path, scope_stack, defines, calls, contains, call_set)
        when "namespace_definition"
          handle_cpp_namespace(node, source, file_path, scope_stack, defines, calls, contains, call_set)
        when "enum_specifier"
          handle_cpp_enum(node, source, file_path, defines)
        when "function_definition"
          handle_cpp_function(node, source, file_path, scope_stack, defines, calls, contains, call_set)
        when "field_declaration"
          cpp_handle_field_declaration(node, source, file_path, scope_stack, defines, contains)
        else
          false
        end
      end

      private def handle_cpp_class(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        name = cpp_declaration_name(node, source)
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(node))
        with_scope(scope_stack, name) do
          walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_cpp_namespace(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        name = cpp_namespace_name(node, source)
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Module, span: Span.from_node(node))
        with_scope(scope_stack, name) do
          walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_cpp_function(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        name = cpp_function_name(node, source)
        return false unless name
        if enclosing = scope_stack.last?
          if cpp_node_has_descendant_type(node, "destructor_name")
            record_cpp_special_method(node, source, file_path, ".dtor", enclosing, scope_stack, defines, contains, calls, call_set)
            return true
          end
          if name == enclosing
            record_cpp_special_method(node, source, file_path, ".ctor", enclosing, scope_stack, defines, contains, calls, call_set)
            return true
          end
        end
        kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
        defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
        with_scope(scope_stack, name) do
          walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def record_cpp_special_method(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        name : String,
        enclosing : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, span: Span.from_node(node))
        contains << ContainsFact.new(parent: enclosing, child: name)
        with_scope(scope_stack, name) do
          walk_cpp_children(node, source, file_path, scope_stack, defines, calls, [] of ImportsFact, [] of ExportsFact, contains, call_set)
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

        defines << DefinesFact.new(file: file_path, name: mname, kind: SymbolKind::Method, span: Span.from_node(node))
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
          if child.type == "destructor_name"
            # Destructor: return the class name without the ~ prefix
            (0...child.named_child_count).each do |gc_idx|
              gc = child.named_child(gc_idx)
              next unless gc
              return gc.text(source) if gc.type == "identifier"
            end
          end
        end
        nil
      end

      private def cpp_namespace_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return nil unless name
        name.text(source)
      end

      private def handle_cpp_enum(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
      ) : Bool
        name = cpp_declaration_name(node, source)
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, span: Span.from_node(node))

        # Extract enumerator members from enumerator_list
        (0...node.named_child_count).each do |child_idx|
          child = node.named_child(child_idx)
          next unless child
          next unless child.type == "enumerator_list"
          (0...child.named_child_count).each do |member_idx|
            member = child.named_child(member_idx)
            next unless member
            next unless member.type == "enumerator"
            member_name = member.child_by_field_name("name").try(&.text(source))
            next unless member_name
            defines << DefinesFact.new(file: file_path, name: member_name, kind: SymbolKind::Variable, span: Span.from_node(member))
          end
        end
        true
      end

      private def cpp_node_has_descendant_type(node : TreeSitter::Node, target_type : String) : Bool
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          return true if child.type == target_type
          return true if cpp_node_has_descendant_type(child, target_type)
        end
        false
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
