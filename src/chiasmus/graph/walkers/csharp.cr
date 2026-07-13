require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_csharp(
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
        return if handle_csharp_declaration(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        handle_csharp_call(node, source, scope_stack, calls, call_set)
        handle_csharp_using(node, source, file_path, imports)

        walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_csharp_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        case node.type
        when "class_declaration", "struct_declaration"
          handle_csharp_class(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        when "interface_declaration"
          handle_csharp_interface(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        when "enum_declaration"
          handle_csharp_enum(node, source, file_path, defines)
        when "method_declaration"
          handle_csharp_method(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        when "constructor_declaration"
          handle_csharp_constructor(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        when "namespace_declaration"
          handle_csharp_namespace(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        else
          false
        end
      end

      private def handle_csharp_class(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        name = node.child_by_field_name("name").try(&.text(source))
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(node))
        with_scope(scope_stack, name) do
          walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_csharp_interface(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        name = node.child_by_field_name("name").try(&.text(source))
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, span: Span.from_node(node))
        with_scope(scope_stack, name) do
          walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_csharp_enum(node, source, file_path, defines)
        name = node.child_by_field_name("name").try(&.text(source))
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, span: Span.from_node(node))

        # Extract enum members from enum_member_declaration_list
        (0...node.named_child_count).each do |child_idx|
          child = node.named_child(child_idx)
          next unless child
          next unless child.type == "enum_member_declaration_list"
          (0...child.named_child_count).each do |member_idx|
            member = child.named_child(member_idx)
            next unless member
            next unless member.type == "enum_member_declaration"
            member_name = member.child_by_field_name("name").try(&.text(source))
            next unless member_name
            defines << DefinesFact.new(file: file_path, name: member_name, kind: SymbolKind::Variable, span: Span.from_node(member))
          end
        end

        true
      end

      private def handle_csharp_method(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        name = node.child_by_field_name("name").try(&.text(source))
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
        with_scope(scope_stack, name) do
          walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_csharp_constructor(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        defines << DefinesFact.new(file: file_path, name: ".ctor", kind: SymbolKind::Method, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: ".ctor")
        end
        with_scope(scope_stack, ".ctor") do
          walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_csharp_namespace(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)
        name = node.child_by_field_name("name").try(&.text(source))
        return true unless name
        with_scope(scope_stack, name) do
          walk_csharp_children(node, source, file_path, scope_stack, defines, calls, imports, [] of ExportsFact, contains, call_set)
        end
        true
      end

      private def handle_csharp_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "invocation_expression"

        callee = resolve_csharp_callee(node, source)
        return unless callee
        record_call(scope_stack.last?, callee, calls, call_set)
      end

      private def resolve_csharp_callee(call_node : TreeSitter::Node, source : String) : String?
        func_node = call_node.child_by_field_name("function")
        if func_node
          if func_node.type == "member_access_expression"
            name = func_node.child_by_field_name("name")
            return name.text(source) if name
          end
          return func_node.text(source)
        end

        nil
      end

      private def handle_csharp_using(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "using_directive"

        import_name = extract_using_name(node, source)
        return unless import_name
        imports << ImportsFact.new(file: file_path, name: import_name, source: import_name)
      end

      private def extract_using_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name").try(&.text(source))
        return name if name && !name.empty?

        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          if child.type.in?("qualified_name", "identifier", "name")
            return child.text(source)
          end
        end
        nil
      end

      private def walk_csharp_children(
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
          walk_csharp(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
