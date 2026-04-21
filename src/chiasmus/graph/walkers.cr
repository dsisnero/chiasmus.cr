require "tree_sitter"
require "./tree_sitter_extensions"

module Chiasmus
  module Graph
    module Walkers
      extend self

      # Walk a generic AST node (for JavaScript/TypeScript-like languages)
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
        return true unless source_node && extract_string_content(source_node, source)

        import_clause = node.children.find { |child_node| child_node.type == "import_clause" }
        extract_import_names(import_clause, file_path, source, imports) if import_clause
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

      # Resolve the callee name from a call_expression node
      private def resolve_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "member_expression"
          # obj.method() → method, this.method() → method
          property = fn_node.child_by_field_name("property")
          property.try(&.text(source))
        when "subscript_expression"
          # Dynamic calls like obj[x]() — not statically resolvable
          nil
        else
          # For other cases (e.g., IIFE, template literals), try the text if short
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      # Find the enclosing class name for a method node
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

      # Extract import names from an import_clause
      private def extract_import_names(
        clause : TreeSitter::Node,
        file_path : String,
        source : String,
        imports : Array(ImportsFact),
      ) : Nil
        clause.children.each do |child|
          # Default import: import foo from './bar'
          if child.type == "identifier"
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: source)
          end

          # Named imports: import { foo, bar } from './baz'
          if child.type == "named_imports"
            child.children.each do |spec|
              if spec.type == "import_specifier"
                name_node = spec.child_by_field_name("name")
                if name_node
                  imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: source)
                end
              end
            end
          end

          # Namespace import: import * as foo from './bar'
          if child.type == "namespace_import"
            name_node = child.children.find { |child_node| child_node.type == "identifier" }
            if name_node
              imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: source)
            end
          end
        end
      end

      # Extract the string content from a string literal node (strip quotes)
      private def extract_string_content(node : TreeSitter::Node, source : String) : String?
        # String nodes have children: quote, string_fragment, quote
        node.children.each do |child|
          if child.type == "string_fragment"
            return child.text(source)
          end
        end

        # Fallback: strip quotes from the full text
        text = node.text(source)
        if (text.starts_with?("'") && text.ends_with?("'")) || (text.starts_with?('"') && text.ends_with?('"'))
          text[1...-1]
        else
          text
        end
      end

      # ── Python walker ───────────────────────────────────────────────

      def walk_python(
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
        return if handle_python_scope(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_python_call(node, source, scope_stack, calls, call_set)
        return if handle_python_import(node, source, file_path, imports)
        return if handle_python_import_from(node, source, file_path, imports)

        walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_python_scope(
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
        when "function_definition"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          enclosing_class = find_python_enclosing_class(node, source)
          kind = enclosing_class ? SymbolKind::Method : SymbolKind::Function
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          contains << ContainsFact.new(parent: enclosing_class, child: name) if enclosing_class
          with_scope(scope_stack, name) do
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "class_definition"
          name = node.child_by_field_name("name").try(&.text(source))
          return false unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          with_scope(scope_stack, name) do
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        else
          false
        end
      end

      private def handle_python_call(
        node : TreeSitter::Node,
        source : String,
        scope_stack : Array(String),
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node.type == "call"

        record_call(scope_stack.last?, resolve_python_callee(node, source), calls, call_set)
      end

      private def handle_python_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_statement"

        node.children.each do |child|
          case child.type
          when "dotted_name"
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: child.text(source))
          when "aliased_import"
            append_python_aliased_import(child, source, file_path, imports, nil)
          end
        end

        true
      end

      private def handle_python_import_from(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Bool
        return false unless node.type == "import_from_statement"

        module_node = node.child_by_field_name("module_name")
        source_name = module_node.try(&.text(source)) || ""
        name_node = node.child_by_field_name("name")
        append_python_direct_import(name_node, source, file_path, imports, source_name) if name_node

        node.children.each do |child|
          if child.type == "dotted_name" && child != module_node && child != name_node
            imports << ImportsFact.new(file: file_path, name: child.text(source), source: source)
          elsif child.type == "aliased_import"
            append_python_aliased_import(child, source, file_path, imports, source)
          end
        end

        true
      end

      private def append_python_direct_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        source_name : String,
      ) : Nil
        return unless node.type == "dotted_name" || node.type == "identifier"

        imports << ImportsFact.new(file: file_path, name: node.text(source), source: source_name)
      end

      private def append_python_aliased_import(
        child : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        import_source : String?,
      ) : Nil
        dotted = child.child_by_field_name("name")
        return unless dotted

        alias_node = child.child_by_field_name("alias")
        alias_name = alias_node ? alias_node.text(source) : dotted.text(source)
        imports << ImportsFact.new(file: file_path, name: alias_name, source: import_source || dotted.text(source))
      end

      private def walk_python_children(
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
          walk_python(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end

      # Resolve callee name from a Python call node
      private def resolve_python_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "attribute"
          # obj.method() → method
          attr = fn_node.child_by_field_name("attribute")
          attr.try(&.text(source))
        else
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      # Find the enclosing class name for a Python method node
      private def find_python_enclosing_class(node : TreeSitter::Node, source : String) : String?
        current = node.parent
        while current
          type = current.type
          if type == "class_definition"
            name_node = current.child_by_field_name("name")
            return name_node.try(&.text(source))
          end
          if type == "block"
            current = current.parent
            next
          end
          current = current.parent
        end
        nil
      end

      # ── Go walker ───────────────────────────────────────────────────

      def walk_go(
        root_node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        root_node.children.each do |node|
          handle_go_declaration(node, source, file_path, defines, calls, exports, contains, call_set)
          handle_go_type_declaration(node, source, file_path, defines, exports)
          handle_go_import_declaration(node, source, file_path, imports)
        end
      end

      private def handle_go_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        case node.type
        when "function_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
          export_name_if_public(name, file_path, exports)
          extract_go_calls(node.child_by_field_name("body"), source, name, calls, call_set)
        when "method_declaration"
          name = node.child_by_field_name("name").try(&.text(source))
          return unless name

          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
          receiver_type = extract_go_receiver_type(node.child_by_field_name("receiver"), source)
          contains << ContainsFact.new(parent: receiver_type, child: name) if receiver_type
          export_name_if_public(name, file_path, exports)
          extract_go_calls(node.child_by_field_name("body"), source, name, calls, call_set)
        end
      end

      private def handle_go_type_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
        exports : Array(ExportsFact),
      ) : Nil
        return unless node.type == "type_declaration"

        node.children.each do |spec|
          next unless spec.type == "type_spec"

          name_node = spec.child_by_field_name("name")
          type_node = spec.child_by_field_name("type")
          next unless name_node && type_node

          name = name_node.text(source)
          kind = type_node.type == "interface_type" ? SymbolKind::Interface : SymbolKind::Class
          defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
          export_name_if_public(name, file_path, exports)
        end
      end

      private def handle_go_import_declaration(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "import_declaration"

        node.children.each do |child|
          if child.type == "import_spec_list"
            child.children.each do |spec|
              append_go_import(spec, source, file_path, imports) if spec.type == "import_spec"
            end
          elsif child.type == "import_spec"
            append_go_import(child, source, file_path, imports)
          end
        end
      end

      private def append_go_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        path_node = node.children.find { |child_node| child_node.type == "interpreted_string_literal" }
        return unless path_node

        import_source = path_node.text(source)[1...-1]
        name = import_source.split("/").last? || import_source
        imports << ImportsFact.new(file: file_path, name: name, source: import_source)
      end

      private def export_name_if_public(name : String, file_path : String, exports : Array(ExportsFact)) : Nil
        exports << ExportsFact.new(file: file_path, name: name) if name.matches?(/^[A-Z]/)
      end

      # Recursively extract call_expression nodes from a Go function body
      private def extract_go_calls(
        node : TreeSitter::Node?,
        source : String,
        caller : String,
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless node

        node.children.each do |child|
          if child.type == "call_expression"
            if callee = resolve_go_callee(child, source)
              key = "#{caller}->#{callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << CallsFact.new(caller: caller, callee: callee)
              end
            end
          end

          extract_go_calls(child, source, caller, calls, call_set)
        end
      end

      # Resolve callee name from a Go call_expression
      private def resolve_go_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "selector_expression"
          # pkg.Func() or obj.Method() → extract the field (right side)
          field = fn_node.child_by_field_name("field")
          field.try(&.text(source))
        else
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      # Extract the receiver type name from a Go method receiver
      private def extract_go_receiver_type(receiver : TreeSitter::Node?, source : String) : String?
        return nil unless receiver
        # receiver is parameter_list: (a *Animal) or (a Animal)
        receiver.children.each do |param|
          if param.type == "parameter_declaration"
            type_node = param.child_by_field_name("type")
            next unless type_node

            # Could be pointer_type (*Animal) or type_identifier (Animal)
            if type_node.type == "pointer_type"
              # First child after * is the type identifier
              type_node.children.each do |child|
                if child.type == "type_identifier"
                  return child.text(source)
                end
              end
            end

            if type_node.type == "type_identifier"
              return type_node.text(source)
            end
          end
        end
        nil
      end

      # ── Clojure walker ──────────────────────────────────────────────

      # Get the text of the first sym_name child (direct or nested in sym_lit)
      private def clj_sym_name(node : TreeSitter::Node, source : String) : String?
        return node.text(source) if node.type == "sym_name"
        if node.type == "sym_lit"
          node.children.each do |child|
            if child.type == "sym_name"
              return child.text(source)
            end
          end
        end
        nil
      end

      # Check if a list_lit is a (defn ...) or (defn- ...) form
      private def clj_defn_name(list_node : TreeSitter::Node, source : String) : NamedTuple(name: String, private: Bool)?
        # First child after ( should be sym_lit with sym_name "defn" or "defn-"
        sym_idx = -1
        list_node.children.each_with_index do |child, i|
          if child.type == "sym_lit"
            sym_idx = i
            break
          end
        end
        return nil if sym_idx < 0

        head = clj_sym_name(list_node.children_array[sym_idx], source)
        return nil unless head == "defn" || head == "defn-"

        # Next sym_lit is the function name
        children_arr = list_node.children_array
        (sym_idx + 1...children_arr.size).each do |i|
          child = children_arr[i]
          if child.type == "sym_lit"
            if name = clj_sym_name(child, source)
              return {name: name, private: head == "defn-"}
            end
          end
        end
        nil
      end

      # Extract ns form: (ns foo.bar (:require [baz.qux :as q] [x.y :refer [z]]))
      private def clj_extract_ns(
        list_node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
      ) : String?
        sym_idx = -1
        list_node.children.each_with_index do |child, i|
          if child.type == "sym_lit"
            sym_idx = i
            break
          end
        end
        return nil if sym_idx < 0

        head = clj_sym_name(list_node.children_array[sym_idx], source)
        return nil unless head == "ns"

        # Namespace name is next sym_lit
        ns_name = nil
        children_arr = list_node.children_array
        (sym_idx + 1...children_arr.size).each do |i|
          child = children_arr[i]
          if child.type == "sym_lit"
            ns_name = clj_sym_name(child, source)
            break
          end
        end

        # Find (:require ...) forms
        list_node.children.each do |child|
          next unless child.type == "list_lit"

          # Check if first element is :require keyword
          child.children.each do |kwd|
            if kwd.type == "kwd_lit"
              kwd_name_node = kwd.children.find { |child_node| child_node.type == "kwd_name" }
              if kwd_name_node && kwd_name_node.text(source) == "require"
                # Extract required namespaces from vec_lit children
                child.children.each do |vec|
                  next unless vec.type == "vec_lit"

                  # First sym_lit in vector is the required namespace
                  vec.children.each do |sym|
                    if sym.type == "sym_lit"
                      if req_ns = clj_sym_name(sym, source)
                        imports << ImportsFact.new(file: file_path, name: req_ns, source: req_ns)
                      end
                      break
                    end
                  end
                end
              end
              break
            end
          end
        end

        ns_name
      end

      # Walk a Clojure AST and extract defines, calls, imports
      def walk_clojure(
        root_node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        call_set : Set(String),
      ) : Nil
        defn_names = Set(String).new # track defined function names

        # First pass: collect top-level forms
        root_node.children.each do |child|
          next unless child.type == "list_lit"

          # Check for ns form
          if clj_extract_ns(child, source, file_path, imports, exports)
            next
          end

          # Check for defn/defn-
          if defn = clj_defn_name(child, source)
            defines << DefinesFact.new(
              file: file_path,
              name: defn[:name],
              kind: SymbolKind::Function,
              line: child.start_point.row.to_i + 1
            )
            defn_names.add(defn[:name])
            unless defn[:private]
              exports << ExportsFact.new(file: file_path, name: defn[:name])
            end
          end
        end

        # Second pass: extract calls within each defn body
        root_node.children.each do |child|
          next unless child.type == "list_lit"

          defn = clj_defn_name(child, source)
          next unless defn

          # Walk the body looking for call sites (list_lit starting with sym_lit)
          clj_extract_calls(child, source, defn[:name], calls, call_set, defn_names)
        end
      end

      # Recursively extract function calls from a Clojure form
      private def clj_extract_calls(
        node : TreeSitter::Node,
        source : String,
        enclosing_fn : String,
        calls : Array(CallsFact),
        call_set : Set(String),
        skip_self : Set(String)?,
      ) : Nil
        node.children.each do |child|
          if child.type == "list_lit"
            # First sym_lit child is the function being called
            child.children.each do |maybe_call|
              if maybe_call.type == "sym_lit"
                if callee = clj_sym_name(maybe_call, source)
                  if callee != enclosing_fn && (!skip_self || !skip_self.includes?(callee))
                    # Strip namespace qualifier: db/query → query
                    if callee.includes?("/")
                      callee = callee.split("/").last
                    end
                    key = "#{enclosing_fn}->#{callee}"
                    unless call_set.includes?(key)
                      call_set.add(key)
                      calls << CallsFact.new(caller: enclosing_fn, callee: callee)
                    end
                  end
                end
                break
              end
            end

            # Recurse into nested forms
            clj_extract_calls(child, source, enclosing_fn, calls, call_set, skip_self)
          end
        end
      end

      # ── Crystal walker ──────────────────────────────────────────────

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
        when "method_def"
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
        when "module_def"
          crystal_container_scope(node, source, file_path, scope_stack, SymbolKind::Interface, defines, calls, imports, exports, contains, call_set)
        else
          false
        end
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

      private def with_scope(scope_stack : Array(String), name : String, & : -> Nil) : Nil
        scope_stack << name
        yield
      ensure
        scope_stack.pop
      end

      private def record_call(
        caller : String?,
        callee : String?,
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless caller && callee

        key = "#{caller}->#{callee}"
        return if call_set.includes?(key)

        call_set.add(key)
        calls << CallsFact.new(caller: caller, callee: callee)
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

      # Resolve callee name from a Crystal call node
      private def resolve_crystal_callee(call_node : TreeSitter::Node, source : String) : String?
        # In Crystal, calls can be:
        # - identifier: method_name()
        # - scoped_identifier: Module::Class.method()
        # - member_access: obj.method()

        # Try to get the method name
        method_node = call_node.child_by_field_name("method")
        return method_node.text(source) if method_node

        # Fallback: look for identifier children
        call_node.children.each do |child|
          if child.type == "identifier"
            return child.text(source)
          end
        end

        nil
      end

      # Find the enclosing class/module name for a Crystal method node
      # Temporarily disabled due to segfault issues
      private def find_crystal_enclosing_class(node : TreeSitter::Node, source : String) : String?
        nil
      end
    end
  end
end
