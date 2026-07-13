require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_proto(
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
        return if handle_proto_declaration(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        handle_proto_import(node, source, file_path, imports)

        walk_proto_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
      end

      private def handle_proto_declaration(
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
        when "message"
          name = proto_find_identifier(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(node))
          with_scope(scope_stack, name) do
            walk_proto_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "service"
          name = proto_find_identifier(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Class, span: Span.from_node(node))
          with_scope(scope_stack, name) do
            walk_proto_children(node, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
          end
          true
        when "rpc"
          name = proto_find_identifier(node, source)
          return false unless name
          defines << DefinesFact.new(file: file_path, name: name, kind: SymbolKind::Method, span: Span.from_node(node))
          if enclosing = scope_stack.last?
            contains << ContainsFact.new(parent: enclosing, child: name)
          end
          true
        else
          false
        end
      end

      private def proto_find_identifier(node : TreeSitter::Node, source : String) : String?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          if child.type == "identifier"
            return child.text(source)
          end
          grandchild = proto_search_identifier(child, source)
          return grandchild if grandchild
        end
        nil
      end

      private def proto_search_identifier(node : TreeSitter::Node, source : String) : String?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          next unless child
          return child.text(source) if child.type == "identifier"
        end
        nil
      end

      private def handle_proto_import(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
      ) : Nil
        return unless node.type == "import"

        str_node = proto_find_child(node, "string")
        return unless str_node

        import_name = str_node.text(source).gsub(/['"]/, "")
        name_part = import_name.split("/").last? || import_name
        imports << ImportsFact.new(file: file_path, name: name_part, source: import_name)
      end

      private def proto_find_child(node : TreeSitter::Node, type : String) : TreeSitter::Node?
        (0...node.named_child_count).each do |i|
          child = node.named_child(i)
          return child if child && child.type == type
        end
        nil
      end

      private def walk_proto_children(
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
          walk_proto(child, source, file_path, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
