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
        handle_dart_node(node, source, file_path, scope_stack, defines, calls, imports, contains, call_set)

        node.children.each do |child|
          walk_dart(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
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
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
        when "function_signature"
          name = dart_name(node, source)
          return unless name
          dart_pop_method_scope(scope_stack)
          kind = scope_stack.last? ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
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
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          scope_stack << name
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
    end
  end
end
