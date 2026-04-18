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
        type = node.type

        case type
        when "function_declaration"
          name_node = node.child_by_field_name("name")
          if name_node
            name = name_node.text(source)
            defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
            scope_stack << name
            walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
            scope_stack.pop
            return # already walked children
          end
        when "method_definition"
          name_node = node.child_by_field_name("name")
          if name_node
            name = name_node.text(source)
            defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
            # Find enclosing class for contains relationship
            if class_name = find_enclosing_class_name(node, source)
              contains << ContainsFact.new(parent: class_name, child: name)
            end
            scope_stack << name
            walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
            scope_stack.pop
            return
          end
        when "class_declaration"
          name_node = node.child_by_field_name("name")
          if name_node
            name = name_node.text(source)
            defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
          end
          # fall through to walk children
        when "lexical_declaration", "variable_declaration"
          # Look for arrow functions: const foo = () => { ... }
          node.children.each do |child|
            if child.type == "variable_declarator"
              name_node = child.child_by_field_name("name")
              value_node = child.child_by_field_name("value")
              if name_node && value_node && value_node.type == "arrow_function"
                name = name_node.text(source)
                defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
                scope_stack << name
                walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
                scope_stack.pop
                return # already walked
              end
            end
          end
        when "call_expression"
          if callee = resolve_callee(node, source)
            caller = scope_stack.last?
            if caller
              key = "#{caller}->#{callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << CallsFact.new(caller: caller, callee: callee)
              end
            end
          end
          # fall through to walk children (nested calls)

        when "import_statement"
          source_node = node.child_by_field_name("source")
          if source_node && (source_name = extract_string_content(source_node, source))
            import_clause = node.children.find { |c| c.type == "import_clause" }
            if import_clause
              extract_import_names(import_clause, file_path, source, imports)
            end
          end
          return # no need to walk deeper
        when "export_statement"
          # export function foo() {} or export class Foo {}
          node.children.each do |child|
            if child.type == "function_declaration" || child.type == "class_declaration"
              name_node = child.child_by_field_name("name")
              if name_node
                exports << ExportsFact.new(file: file_path, name: name_node.text(source))
              end
            end

            if child.type == "lexical_declaration" || child.type == "variable_declaration"
              child.children.each do |decl|
                if decl.type == "variable_declarator"
                  name_node = decl.child_by_field_name("name")
                  if name_node
                    exports << ExportsFact.new(file: file_path, name: name_node.text(source))
                  end
                end
              end
            end

            # export { foo, bar }
            if child.type == "export_clause"
              child.children.each do |spec|
                if spec.type == "export_specifier"
                  name_node = spec.child_by_field_name("name")
                  if name_node
                    exports << ExportsFact.new(file: file_path, name: name_node.text(source))
                  end
                end
              end
            end
          end

          # Check for re-exports: export { foo } from './bar'
          re_source = node.child_by_field_name("source")
          if re_source && (source_name = extract_string_content(re_source, source))
            export_clause = node.children.find { |c| c.type == "export_clause" }
            if export_clause
              export_clause.children.each do |spec|
                if spec.type == "export_specifier"
                  name_node = spec.child_by_field_name("name")
                  if name_node
                    imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: source_name)
                  end
                end
              end
            end
          end
          # fall through to walk children (may contain function_declaration etc.)
        end

        walk_children(node, source, file_path, language, scope_stack, defines, calls, imports, exports, contains, call_set)
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
            name_node = child.children.find { |c| c.type == "identifier" }
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
        type = node.type

        case type
        when "function_definition"
          name_node = node.child_by_field_name("name")
          if name_node
            name = name_node.text(source)
            enclosing_class = find_python_enclosing_class(node, source)
            kind = enclosing_class ? SymbolKind::Method : SymbolKind::Function
            defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)
            if enclosing_class
              contains << ContainsFact.new(parent: enclosing_class, child: name)
            end
            scope_stack << name
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
            scope_stack.pop
            return
          end
        when "class_definition"
          name_node = node.child_by_field_name("name")
          if name_node
            name = name_node.text(source)
            defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
            scope_stack << name
            walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
            scope_stack.pop
            return
          end
        when "decorated_definition"
          # Walk into the actual definition inside the decorator
          # fall through

        when "call"
          if callee = resolve_python_callee(node, source)
            caller = scope_stack.last?
            if caller
              key = "#{caller}->#{callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << CallsFact.new(caller: caller, callee: callee)
              end
            end
          end
        when "import_statement"
          # import os, sys
          node.children.each do |child|
            if child.type == "dotted_name"
              imports << ImportsFact.new(file: file_path, name: child.text(source), source: child.text(source))
            end
            if child.type == "aliased_import"
              dotted = child.child_by_field_name("name")
              if dotted
                alias_node = child.child_by_field_name("alias")
                alias_name = alias_node ? alias_node.text(source) : dotted.text(source)
                imports << ImportsFact.new(file: file_path, name: alias_name, source: dotted.text(source))
              end
            end
          end
          return
        when "import_from_statement"
          # from pathlib import Path
          module_node = node.child_by_field_name("module_name")
          source_name = module_node.try(&.text(source)) || ""
          name_node = node.child_by_field_name("name")
          if name_node
            # Could be a single dotted_name or multiple via import list
            if name_node.type == "dotted_name" || name_node.type == "identifier"
              imports << ImportsFact.new(file: file_path, name: name_node.text(source), source: source_name)
            end
          end

          # Handle multiple imports: from x import a, b, c
          node.children.each do |child|
            if child.type == "dotted_name" && child != module_node && child != name_node
              imports << ImportsFact.new(file: file_path, name: child.text(source), source: source)
            end
            if child.type == "aliased_import"
              import_name = child.child_by_field_name("name")
              alias_node = child.child_by_field_name("alias")
              if import_name
                alias_name = alias_node ? alias_node.text(source) : import_name.text(source)
                imports << ImportsFact.new(file: file_path, name: alias_name, source: source)
              end
            end
          end
          return
        end

        walk_python_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
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
          type = node.type

          case type
          when "function_declaration"
            name_node = node.child_by_field_name("name")
            if name_node
              name = name_node.text(source)
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Function, line: node.start_point.row.to_i + 1)
              if name.matches?(/^[A-Z]/)
                exports << ExportsFact.new(file: file_path, name: name)
              end
              extract_go_calls(node.child_by_field_name("body"), source, name, calls, call_set)
            end
          when "method_declaration"
            name_node = node.child_by_field_name("name")
            if name_node
              name = name_node.text(source)
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, line: node.start_point.row.to_i + 1)
              # Extract receiver type for contains relationship
              receiver = node.child_by_field_name("receiver")
              receiver_type = extract_go_receiver_type(receiver, source)
              if receiver_type
                contains << ContainsFact.new(parent: receiver_type, child: name)
              end
              if name.matches?(/^[A-Z]/)
                exports << ExportsFact.new(file: file_path, name: name)
              end
              extract_go_calls(node.child_by_field_name("body"), source, name, calls, call_set)
            end
          when "type_declaration"
            # type Foo struct { ... } or type Foo interface { ... }
            node.children.each do |spec|
              if spec.type == "type_spec"
                name_node = spec.child_by_field_name("name")
                type_node = spec.child_by_field_name("type")
                if name_node && type_node
                  kind = type_node.type == "interface_type" ? SymbolKind::Interface : SymbolKind::Class
                  defines << DefinesFact.new(file: file_path, name: name_node.text(source), kind: kind, line: node.start_point.row.to_i + 1)
                  if name_node.text(source).matches?(/^[A-Z]/)
                    exports << ExportsFact.new(file: file_path, name: name_node.text(source))
                  end
                end
              end
            end
          when "import_declaration"
            node.children.each do |child|
              if child.type == "import_spec_list"
                child.children.each do |spec|
                  if spec.type == "import_spec"
                    path_node = spec.children.find { |c| c.type == "interpreted_string_literal" }
                    if path_node
                      source = path_node.text(source)[1...-1] # strip quotes
                      name = source.split("/").last? || source
                      imports << ImportsFact.new(file: file_path, name: name, source: source)
                    end
                  end
                end
              end

              # Single import without parens
              if child.type == "import_spec"
                path_node = child.children.find { |c| c.type == "interpreted_string_literal" }
                if path_node
                  source = path_node.text(source)[1...-1]
                  name = source.split("/").last? || source
                  imports << ImportsFact.new(file: file_path, name: name, source: source)
                end
              end
            end
          end
        end
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
              kwd_name_node = kwd.children.find { |c| c.type == "kwd_name" }
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
        type = node.type

        case type
        when "method_def"
          # Crystal method definition: def method_name or def self.method_name
          # Find the name identifier and check for self receiver
          name = nil
          is_class_method = false
          found_self = false
          found_dot = false

          node.children.each do |child|
            case child.type
            when "identifier"
              # This is the method name if we haven't found it yet
              # and we're not in the middle of a self. pattern
              if name.nil? && !found_self
                name = child.text(source)
              elsif name.nil? && found_self && found_dot
                # This is the method name after self.
                name = child.text(source)
                is_class_method = true
              end
            when "self"
              found_self = true
            when "."
              found_dot = true
            end
          end

          if name
            # Determine method kind based on receiver
            kind = if is_class_method
                     SymbolKind::Method
                   else
                     SymbolKind::Function
                   end

            # Get enclosing class/module from scope stack
            enclosing = scope_stack.last?

            defines << DefinesFact.new(file: file_path, name: name, kind: kind, line: node.start_point.row.to_i + 1)

            # Create contains relationship if there's an enclosing class/module
            if enclosing
              contains << ContainsFact.new(parent: enclosing, child: name)
            end

            scope_stack << name
            walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
            scope_stack.pop
            return
          end
        when "class_def"
          # Crystal class definition: class ClassName
          # Find the name (constant child)
          node.children.each do |child|
            if child.type == "constant"
              name = child.text(source)
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
              scope_stack << name
              walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
              scope_stack.pop
              return
            end
          end
        when "module_def"
          # Crystal module definition: module ModuleName
          # Find the name (constant child)
          node.children.each do |child|
            if child.type == "constant"
              name = child.text(source)
              defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Interface, line: node.start_point.row.to_i + 1)
              scope_stack << name
              walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
              scope_stack.pop
              return
            end
          end
        when "call"
          # Method call: method_name(arg1, arg2) or obj.method_name(arg1, arg2)
          # Check if this is a require_relative call
          callee = resolve_crystal_callee(node, source)

          if callee == "require_relative"
            # Handle require_relative "./other_file"
            # Look for argument_list with string
            node.children.each do |child|
              if child.type == "argument_list"
                child.children.each do |arg|
                  if arg.type == "string"
                    source_name = extract_string_content(arg, source)
                    if source_name
                      imports << ImportsFact.new(file: file_path, name: source_name, source: source_name)
                    end
                  end
                end
              end
            end
            return
          elsif callee
            # Regular method call
            caller = scope_stack.last?
            if caller
              key = "#{caller}->#{callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << CallsFact.new(caller: caller, callee: callee)
              end
            end
          end
        when "require"
          # require "library"
          # Look for string child manually (child_by_field_name doesn't work for Crystal)
          node.children.each do |child|
            if child.type == "string"
              source_name = extract_string_content(child, source)
              if source_name
                # Extract library name from path
                lib_name = File.basename(source_name, ".cr")
                imports << ImportsFact.new(file: file_path, name: lib_name, source: source_name)
              end
              return
            end
          end
          return
        end

        walk_crystal_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
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
