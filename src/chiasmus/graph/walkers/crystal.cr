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

      # ameba:disable Metrics/CyclomaticComplexity
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
          qualified_name = crystal_qualified_name(scope_stack, crystal_method_name)
          defines << DefinesFact.new(file: file_path, name: crystal_method_name, kind: kind, span: Span.from_node(node), qualified_name: qualified_name)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: crystal_method_name)
          end
          with_scope(scope_stack, crystal_method_name) do
            walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "macro_def"
          crystal_callable_scope(node, source, file_path, scope_stack, SymbolKind::Function, defines, calls, imports, exports, contains, call_set)
        when "fun_def"
          crystal_callable_scope(node, source, file_path, scope_stack, SymbolKind::Function, defines, calls, imports, exports, contains, call_set)
        when "class_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "struct_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "c_struct_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "union_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Class, defines, calls, imports, exports, contains, call_set)
        when "module_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Interface, defines, calls, imports, exports, contains, call_set)
        when "lib_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Module, defines, calls, imports, exports, contains, call_set)
        when "enum_def"
          crystal_enum_scope(node, source, file_path, scope_stack, defines, contains)
        when "alias"
          crystal_alias_scope(node, source, file_path, scope_stack, defines, contains)
        when "type_def"
          crystal_type_definition(node, source, file_path, scope_stack, defines, contains)
        when "annotation_def"
          crystal_simple_definition(node, source, file_path, scope_stack, SymbolKind::Type, defines, contains)
        when "const_assign"
          crystal_constant_definition(node, source, file_path, scope_stack, defines, contains)
        else
          false
        end
      end

      # ameba:enable Metrics/CyclomaticComplexity

      private def crystal_callable_scope(
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
        name = crystal_name_field(node, source)
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
        with_scope(scope_stack, name) do
          walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
        true
      end

      private def crystal_alias_scope(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        name = crystal_name_field(node, source)
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end

        # Extract aliased types (direct constants or union_type children)
        node.children.each do |child|
          case child.type
          when "constant"
            child_name = child.text(source)
            next if child_name == name
            defines << DefinesFact.new(file: file_path, name: child_name, kind: SymbolKind::Type, span: Span.from_node(child))
          when "union_type"
            child.children.each do |union_child|
              next unless union_child.type == "constant"
              union_name = union_child.text(source)
              defines << DefinesFact.new(file: file_path, name: union_name, kind: SymbolKind::Type, span: Span.from_node(union_child))
            end
          end
        end

        true
      end

      private def crystal_enum_scope(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        name = crystal_name_field(node, source)
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end

        # Extract enum members (constants/const_assign inside the enum body)
        node.children.each do |child|
          next unless child.type == "expressions"
          child.children.each do |member|
            member_name = case member.type
                          when "constant"
                            member.text(source)
                          when "const_assign"
                            name_node = member.children.find(&.type.==("constant"))
                            name_node.try(&.text(source))
                          else
                            nil
                          end
            next unless member_name
            next if member_name == name
            defines << DefinesFact.new(file: file_path, name: member_name, kind: SymbolKind::Variable, span: Span.from_node(member))
          end
        end

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
        name = crystal_name_field(node, source)
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
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

        record_crystal_call(scope_stack, callee, calls, call_set, qualify_callee: crystal_call_without_receiver?(node))
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
        return if skip_crystal_identifier_parent?(parent)

        text = node.text(source)
        record_crystal_call(scope_stack, text, calls, call_set, qualify_callee: true)
      end

      private def skip_crystal_identifier_parent?(parent : TreeSitter::Node) : Bool
        return true if parent.type.in?("method_def", "abstract_method_def", "parameters")
        return true if parent.type.in?("call", "assignment", "binary", "return_statement")

        # Allow calls where parent is an expression container (bare method calls)
        return false if parent.type.in?("expressions", "then", "else", "elsif", "when", "begin", "ensure", "body_statement")

        # Allow calls with argument_list sibling (explicit calls without call wrapper)
        return false if has_argument_list_sibling?(parent)

        # Default: skip — not in a call context
        true
      end

      private def has_argument_list_sibling?(parent : TreeSitter::Node) : Bool
        parent.children.each do |sibling|
          return true if sibling.type == "argument_list"
        end
        false
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

      private def crystal_call_without_receiver?(call_node : TreeSitter::Node) : Bool
        call_node.child_by_field_name("object").nil? &&
          call_node.child_by_field_name("receiver").nil?
      end

      private def crystal_qualified_name(scope_stack : Array(String), name : String) : String
        return name if scope_stack.empty?
        "#{scope_stack.join('.')}.#{name}"
      end

      private def record_crystal_call(
        scope_stack : Array(String),
        callee : String?,
        calls : Array(CallsFact),
        call_set : Set(String),
        qualify_callee : Bool,
      ) : Nil
        caller = scope_stack.last?
        return unless caller && callee

        caller_qn = scope_stack.join('.')
        callee_qn = if qualify_callee && scope_stack.size > 1
                      "#{scope_stack[0...-1].join('.')}.#{callee}"
                    end
        key = "#{caller}\u0000#{callee}\u0000#{caller_qn}\u0000#{callee_qn}"
        return if call_set.includes?(key)

        call_set.add(key)
        calls << CallsFact.new(caller: caller, callee: callee, callee_qn: callee_qn, caller_qn: caller_qn)
      end

      private def find_crystal_enclosing_class(node : TreeSitter::Node, source : String) : String?
        nil
      end

      private def crystal_type_definition(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        crystal_simple_definition(node, source, file_path, scope_stack, SymbolKind::Type, defines, contains)
      end

      private def crystal_constant_definition(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        name_node = node.child_by_field_name("lhs") || node.children.find(&.type.==("constant"))
        name = name_node.try(&.text(source))
        return false unless name
        return false unless name.matches?(/^[A-Z][A-Z0-9_]*$/)

        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Variable, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
        true
      end

      private def crystal_simple_definition(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        kind : SymbolKind,
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        name = crystal_name_field(node, source)
        return false unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: name)
        end
        true
      end

      private def crystal_name_field(node : TreeSitter::Node, source : String) : String?
        node.child_by_field_name("name").try { |name_node| crystal_name_token(name_node, source) } ||
          node.children.find(&.type.==("constant")).try(&.text(source)) ||
          node.children.find(&.type.==("identifier")).try(&.text(source))
      end

      private def crystal_name_token(node : TreeSitter::Node, source : String) : String?
        return node.text(source) if node.type.in?("constant", "identifier")

        node.children.each do |child|
          name = crystal_name_token(child, source)
          return name if name
        end

        nil
      end
    end
  end
end
