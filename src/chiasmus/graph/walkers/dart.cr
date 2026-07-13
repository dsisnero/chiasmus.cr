require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_dart(
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
        class_scope = dart_enter_scope(node, source, scope_stack)
        handle_dart_node(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)

        node.children.each do |child|
          walk_dart(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end

        scope_stack.pop if class_scope
      end

      private def dart_enter_scope(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
      ) : String?
        case node.type
        when "class_definition"
          name = dart_name(node, source)
          if name
            scope_stack << name
            name
          end
        end
      end

      private def handle_dart_node(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        case node.type
        when "class_definition"
          name = dart_name(node, source)
          return unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(node))
          if scope_stack.size > 1 && (enclosing = scope_stack[-2]?)
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
        when "constructor_signature", "factory_constructor_signature", "constant_constructor_signature"
          handle_dart_constructor(node, source, file_path, scope_stack, defines, contains)
        when "enum_declaration"
          handle_dart_enum(node, source, file_path, defines)
        when "function_signature"
          name = dart_name(node, source)
          return unless name
          dart_pop_method_scope(scope_stack)
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, span: Span.from_node(node))
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          scope_stack << name
        when "method_signature"
          sig = dart_find_child(node, "function_signature")
          return unless sig
          name = dart_name(sig, source)
          return unless name
          dart_pop_method_scope(scope_stack)
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, span: Span.from_node(node))
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
        when "expression_statement"
          handle_dart_call(node, source, scope_stack, calls, call_set)
        when "import_or_export"
          handle_dart_import(node, source, file_path, imports)
        end
      end

      private def dart_pop_method_scope(scope_stack : Array(String)) : Nil
        if scope_stack.last? && !scope_stack.last?.try(&.[0]?.try(&.uppercase?))
          scope_stack.pop
        end
      end

      private def dart_name(node : TreeSitter::Node, source : String) : String?
        name = node.child_by_field_name("name")
        return name.text(source) if name
        dart_find_child(node, "identifier").try(&.text(source))
      end

      private def dart_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def handle_dart_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        callee = nil
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          if child.type == "selector"
            has_args = false
            (0...child.named_child_count).each do |j|
              gc = child.named_child(j)
              if gc && gc.type == "argument_part"
                has_args = true
                break
              end
            end
            if has_args && i > 0
              prev = node.named_child(i - 1)
              if prev && prev.type == "identifier"
                callee = prev.text(source)
              end
            end
          end
        end
        return unless callee

        record_call(scope_stack.last?, callee, calls, call_set)
      end

      private def handle_dart_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        lib_import = dart_find_child(node, "library_import")
        return unless lib_import

        import_spec = dart_find_child(lib_import, "import_specification")
        return unless import_spec

        config_uri = dart_find_child(import_spec, "configurable_uri")
        return unless config_uri

        uri = dart_find_child(config_uri, "uri")
        return unless uri

        str_lit = dart_find_child(uri, "string_literal")
        return unless str_lit

        import_name = str_lit.text(source).gsub(/['"]/, "")
        name_part = import_name.split("/").last? || import_name
        imports << ImportsFact.new(file: file_path, name: name_part, source: import_name)
      end

      private def handle_dart_enum(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
      ) : Bool
        name = node.child_by_field_name("name").try(&.text(source))
        return false unless name
        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Type, span: Span.from_node(node))

        enum_body = dart_find_child(node, "enum_body")
        if enum_body
          (0...enum_body.named_child_count).each do |i|
            constant = enum_body.named_child(i)
            next unless constant && constant.type == "enum_constant"
            constant_name = constant.child_by_field_name("name").try(&.text(source))
            next unless constant_name
            defines << DefinesFact.new(file: file_path, name: constant_name, kind: SymbolKind::Variable, span: Span.from_node(constant))
          end
        end

        true
      end

      private def handle_dart_constructor(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        contains : Array(ContainsFact),
      ) : Bool
        return false unless scope_stack.last?
        defines << DefinesFact.new(file: file_path, name: ".ctor", kind: SymbolKind::Method, span: Span.from_node(node))
        if enclosing = scope_stack.last?
          contains << ContainsFact.new(parent: enclosing, child: ".ctor")
        end
        true
      end
    end
  end
end
