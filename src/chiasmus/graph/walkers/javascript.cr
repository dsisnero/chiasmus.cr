require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_node(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        language : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        return if handle_js_scoped_definition(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_js_definition(node, source, file_path, defines)
        handle_js_call(node, source, scope_stack, calls, call_set)
        return if handle_js_import(node, source, file_path, imports)
        handle_js_export(node, source, file_path, imports, exports)

        walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_js_scoped_definition(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        language : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        case node.type
        when "function_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "method_definition"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
          if class_name = find_enclosing_class_name(node, source)
            contains << ContainsFact.new(parent: class_name, child: name)
          end
          with_scope(scope_stack, name) do
            walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "lexical_declaration", "variable_declaration"
          handle_js_arrow_function(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
        else
          false
        end
      end

      private def handle_js_arrow_function(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        language : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Bool
        node.children.each do |child|
          next unless child.type == "variable_declarator"

          name_node = child.child_by_field_name("name")
          value_node = child.child_by_field_name("value")
          next unless name_node && value_node && value_node.type == "arrow_function"

          name = name_node.text(source)
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          return true
        end

        false
      end

      private def handle_js_definition(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
      ) : Nil
        return unless node.type == "class_declaration"

        name = node.child_by_field_name("name").try(&.text(source))
        return unless name

        defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
      end

      private def handle_js_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call_expression"

        callee = resolve_callee(node, source)
        caller = scope_stack.last?
        record_call(caller, callee, calls, call_set)
      end

      private def handle_js_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_statement"

        source_node = node.child_by_field_name("source")
        module_path = source_node && extract_string_content(source_node, source)
        return true unless module_path

        import_clause = node.children.find { |child_node| child_node.type == "import_clause" }
        extract_import_names(import_clause, file_path, source, module_path, imports) if import_clause
        true
      end

      private def handle_js_export(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
      ) : Nil
        return unless node.type == "export_statement"

        extract_exported_names(node, source, file_path, exports)
        extract_reexports(node, source, file_path, imports)
      end

      private def extract_exported_names(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        exports : Array(ExportsFact),
      ) : Nil
        node.children.each do |child|
          case child.type
          when "function_declaration", "class_declaration"
            export_named_child(child, source, file_path, exports)
          when "lexical_declaration", "variable_declaration"
            export_variable_declaration(child, source, file_path, exports)
          when "export_clause"
            export_clause_names(child, source, file_path, exports)
          end
        end
      end

      private def extract_reexports(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        re_source = node.child_by_field_name("source")
        source_name = re_source.try { |ref| extract_string_content(ref, source) }
        return unless source_name

        export_clause = node.children.find { |child_node| child_node.type == "export_clause" }
        return unless export_clause

        export_clause.children.each do |spec|
          next unless spec.type == "export_specifier"

          name_node = spec.child_by_field_name("name")
          next unless name_node

          imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: source_name)
        end
      end

      private def export_named_child(
        child : TreeSitter::Node,
        source : String,
        file_path : String,
        exports : Array(ExportsFact),
      ) : Nil
        name_node = child.child_by_field_name("name")
        return unless name_node

        exports << ExportsFact.new(file: file_path, name: name_node.text(source))
      end

      private def export_variable_declaration(
        child : TreeSitter::Node,
        source : String,
        file_path : String,
        exports : Array(ExportsFact),
      ) : Nil
        child.children.each do |decl|
          next unless decl.type == "variable_declarator"

          name_node = decl.child_by_field_name("name")
          next unless name_node

          exports << ExportsFact.new(file: file_path, name: name_node.text(source))
        end
      end

      private def export_clause_names(
        child : TreeSitter::Node,
        source : String,
        file_path : String,
        exports : Array(ExportsFact),
      ) : Nil
        child.children.each do |spec|
          next unless spec.type == "export_specifier"

          name_node = spec.child_by_field_name("name")
          next unless name_node

          exports << ExportsFact.new(file: file_path, name: name_node.text(source))
        end
      end

      private def walk_children(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        language : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        node.children.each do |child|
          walk_node(child, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      private def resolve_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "member_expression"
          property = fn_node.child_by_field_name("property")
          property.try(&.text(source))
        when "subscript_expression"
          nil
        else
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      private def find_enclosing_class_name(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          type = current.type
          if type == "class_declaration" || type == "class"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          end
          if type == "class_body"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end

      private def extract_import_names(
        clause : TreeSitter::Node,
        file_path : String,
        source : String,
        import_source : String,
        imports : Array(ImportsFact),
      ) : Nil
        clause.children.each do |child|
          if child.type == "identifier"
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: import_source)
          end

          if child.type == "named_imports"
            child.children.each do |spec|
              if spec.type == "import_specifier"
                name_node = spec.child_by_field_name("name")
                if name_node
                  imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: import_source)
                end
              end
            end
          end

          if child.type == "namespace_import"
            name_node = child.children.find { |child_node| child_node.type == "identifier" }
            if name_node
              imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: import_source)
            end
          end
        end
      end
    end
  end
end
