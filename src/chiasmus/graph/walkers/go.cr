require "../types"

module Chiasmus
  module Graph
    module Walkers
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

      private def resolve_go_callee(call_node : TreeSitter::Node, source : String) : String?
        fn_node = call_node.child_by_field_name("function")
        return nil unless fn_node

        case fn_node.type
        when "identifier"
          fn_node.text(source)
        when "selector_expression"
          field = fn_node.child_by_field_name("field")
          field.try(&.text(source))
        else
          fn_node.text(source).size <= 50 ? fn_node.text(source) : nil
        end
      end

      private def extract_go_receiver_type(receiver : TreeSitter::Node?, source : String) : String?
        return nil unless receiver
        receiver.children.each do |param|
          if param.type == "parameter_declaration"
            type_node = param.child_by_field_name("type")
            next unless type_node

            if type_node.type == "pointer_type"
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
    end
  end
end
