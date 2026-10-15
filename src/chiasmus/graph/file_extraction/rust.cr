module Chiasmus
  module Graph
    module FileExtraction
      RUST_NODE_KINDS = {
        "mod_item"          => "module",
        "struct_item"       => "struct",
        "enum_item"         => "enum",
        "trait_item"        => "trait",
        "union_item"        => "union",
        "type_item"         => "type_alias",
        "const_item"        => "constant",
        "static_item"       => "variable",
        "field_declaration" => "field",
        "enum_variant"      => "enum_variant",
      }

      private def rust_declarations(root : TreeSitter::Node, source : String, file_path : String, logical_path : String?) : Array(Declaration)
        declarations = [] of Declaration
        rust_walk(root, source, file_path, logical_path, [] of String, [] of String, declarations)
        declarations
      end

      private def rust_walk(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, modules : Array(String), owners : Array(String), declarations : Array(Declaration)) : Nil
        kind = rust_kind(node.type, owners)
        name_node = node.child_by_field_name("name")
        if kind && name_node
          name = name_node.text(source)
          declarations << rust_declaration(node, name_node, source, file_path, logical_path, modules, owners, kind, name)
          if node.type == "mod_item"
            modules = modules + [name]
          elsif node.type.in?("struct_item", "enum_item", "trait_item", "union_item")
            owners = owners + [name]
          end
        elsif node.type == "impl_item"
          if type_node = node.child_by_field_name("type")
            owners = owners + [type_node.text(source)]
          end
        end

        return if node.type.in?("function_item", "function_signature_item")

        node.children.each do |child|
          rust_walk(child, source, file_path, logical_path, modules, owners, declarations)
        end
      end

      private def rust_kind(node_type : String, owners : Array(String)) : String?
        return owners.empty? ? "function" : "method" if node_type.in?("function_item", "function_signature_item")
        RUST_NODE_KINDS[node_type]?
      end

      private def rust_declaration(node : TreeSitter::Node, name_node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, modules : Array(String), owners : Array(String), kind : String, name : String) : Declaration
        namespace = modules.empty? ? nil : modules.join(".")
        owner_parts = modules + owners
        owner = owner_parts.empty? ? nil : owner_parts.join(".")
        qualified_name = (owner_parts + [name]).join(".")
        parameters = rust_parameters(node, source)
        return_type = node.child_by_field_name("return_type").try(&.text(source)) || node.child_by_field_name("type").try(&.text(source))
        overload_key = parameters.try { |items| "(#{items.map { |item| item.type_name || "?" }.join(",")})" }
        visibility = rust_visibility(node, source)
        Declaration.new(
          language: "rust", namespace: namespace, owner: owner, kind: kind, name: name,
          qualified_name: qualified_name, file: file_path, span: Span.from_node(node),
          ast_node_type: node.type, extraction_method: "tree_sitter_ast",
          signature: java_signature(parameters, return_type), parameters: parameters,
          return_type: return_type, visibility: visibility,
          static: rust_static(kind, parameters),
          abstract: node.type == "function_signature_item" ? true : nil,
          mutable: rust_mutable(kind),
          legacy_aliases: ["#{file_path}::#{rust_legacy_kind(kind)}::#{qualified_name}"],
          declaration_id: DeclarationIdentity.declaration_id(DeclarationIdentityInput.new(
            language: "rust", namespace: namespace, owner_chain: owners,
            kind: kind, name: name, overload_key: overload_key,
          )),
          occurrence_id: occurrence_id(logical_path, name_node),
        )
      end

      private def rust_legacy_kind(kind : String) : String
        return "class" if kind.in?("struct", "enum", "union")
        return "interface" if kind.in?("trait", "module")
        return "type" if kind.in?("type_alias", "enum_variant")
        return "const" if kind == "constant"
        kind
      end

      private def rust_static(kind : String, parameters : Array(Parameter)?) : Bool?
        return true if kind.in?("constant", "variable")
        return !rust_receiver?(parameters) if kind == "method"
        nil
      end

      private def rust_mutable(kind : String) : Bool?
        return false if kind == "constant"
        return true if kind.in?("field", "variable")
        nil
      end

      private def rust_parameters(node : TreeSitter::Node, source : String) : Array(Parameter)?
        list = node.child_by_field_name("parameters")
        return nil unless list
        list.children.compact_map do |child|
          case child.type
          when "self_parameter"
            Parameter.new(name: "self", type_name: child.text(source))
          when "parameter"
            pattern = child.child_by_field_name("pattern")
            next unless pattern
            Parameter.new(name: pattern.text(source), type_name: child.child_by_field_name("type").try(&.text(source)))
          end
        end.to_a
      end

      private def rust_receiver?(parameters : Array(Parameter)?) : Bool
        parameters.try(&.any? { |parameter| parameter.name == "self" }) || false
      end

      private def rust_visibility(node : TreeSitter::Node, source : String) : String
        modifier = node.children.find(&.type.==("visibility_modifier"))
        return "private" unless modifier
        text = modifier.text(source)
        return "public" if text == "pub"
        text
      end
    end
  end
end
