module Chiasmus
  module Graph
    module FileExtraction
      private def crystal_declarations(root : TreeSitter::Node, source : String, file_path : String, logical_path : String?) : Array(Declaration)
        declarations = [] of Declaration
        crystal_walk(root, source, file_path, logical_path, [] of String, [] of String, nil, declarations)
        declarations
      end

      private def crystal_walk(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), visibility : String?, declarations : Array(Declaration)) : Nil
        if node.type == "visibility_modifier"
          modifier = node.child_by_field_name("visibility").try(&.text(source))
          node.children.each { |child| crystal_walk(child, source, file_path, logical_path, names, modules, modifier, declarations) }
          return
        end

        if node.type == "macro_begin"
          crystal_macro_constants(node, source, file_path, logical_path, names, modules, declarations)
          return
        end

        kind = crystal_container_kind(node.type)
        if kind
          if name_node = node.child_by_field_name("name")
            name = name_node.text(source)
            declarations << crystal_declaration(node, source, file_path, logical_path, names, modules, kind, name, visibility)
            next_modules = kind == "module" ? modules + [name] : modules
            if kind == "enum"
              crystal_enum_members(node, source, file_path, logical_path, names + [name], next_modules, declarations)
              return
            end
            node.children.each { |child| crystal_walk(child, source, file_path, logical_path, names + [name], next_modules, nil, declarations) }
            return
          end
        end

        if node.type.in?("method_def", "abstract_method_def", "fun_def", "macro_def")
          if name = crystal_callable_name(node, source)
            callable_kind = crystal_callable_kind(node.type, names)
            declarations << crystal_declaration(node, source, file_path, logical_path, names, modules, callable_kind, name, visibility)
          end
          crystal_method_fields(node, source, file_path, logical_path, names, modules, declarations)
          return
        end

        if node.type == "const_assign"
          if name_node = node.child_by_field_name("lhs")
            name = name_node.text(source)
            declarations << crystal_declaration(node, source, file_path, logical_path, names, modules, "constant", name, visibility)
          end
          return
        end

        if node.type.in?("type_declaration", "assign")
          crystal_field(node, source, file_path, logical_path, names, modules, visibility, declarations)
          return
        end

        node.children.each { |child| crystal_walk(child, source, file_path, logical_path, names, modules, visibility, declarations) }
      end

      private def crystal_macro_constants(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), declarations : Array(Declaration)) : Nil
        body = node.child_by_field_name("body")
        return unless body
        pending = nil.as(String?)
        body.children.each do |child|
          case child.type
          when "macro_content"
            pending = child.text(source).match(/(?:^|\n)\s*([A-Z][A-Z0-9_]*)\s*=\s*\z/).try(&.[1]?)
          when "macro_expression"
            if name = pending
              declarations << crystal_declaration(child, source, file_path, logical_path, names, modules, "constant", name, nil, "macro_inference")
            end
            pending = nil
          else
            pending = nil
          end
        end
      end

      private def crystal_enum_members(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), declarations : Array(Declaration)) : Nil
        body = node.child_by_field_name("body")
        return unless body
        body.children.each do |member|
          member_node = member.type == "const_assign" ? member.child_by_field_name("lhs") : member
          next unless member_node && member_node.type == "constant"
          declarations << crystal_declaration(member, source, file_path, logical_path, names, modules, "enum_member", member_node.text(source), nil)
        end
      end

      private def crystal_field(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), visibility : String?, declarations : Array(Declaration)) : Nil
        return if names.empty?
        field_node = node.child_by_field_name(node.type == "assign" ? "lhs" : "var")
        return unless field_node && field_node.type.in?("instance_var", "class_var")
        declaration = crystal_declaration(node, source, file_path, logical_path, names, modules, "field", field_node.text(source), visibility)
        existing_index = declarations.index { |item| item.kind == "field" && item.owner == declaration.owner && item.name == declaration.name }
        if index = existing_index
          declarations[index] = declaration if declarations[index].return_type.nil? && declaration.return_type
        else
          declarations << declaration
        end
      end

      private def crystal_method_fields(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), declarations : Array(Declaration)) : Nil
        node.children.each do |child|
          if child.type == "assign"
            crystal_field(child, source, file_path, logical_path, names, modules, nil, declarations)
          else
            crystal_method_fields(child, source, file_path, logical_path, names, modules, declarations)
          end
        end
      end

      private def crystal_container_kind(node_type : String) : String?
        case node_type
        when "module_def"     then "module"
        when "class_def"      then "class"
        when "struct_def"     then "struct"
        when "enum_def"       then "enum"
        when "lib_def"        then "lib"
        when "union_def"      then "union"
        when "c_struct_def"   then "c_struct"
        when "alias"          then "type_alias"
        when "type_def"       then "type_def"
        when "annotation_def" then "annotation"
        end
      end

      private def crystal_callable_kind(node_type : String, names : Array(String)) : String
        return "macro" if node_type == "macro_def"
        return "function" if node_type == "fun_def" || names.empty?
        "method"
      end

      private def crystal_callable_name(node : TreeSitter::Node, source : String) : String?
        node.child_by_field_name("name").try(&.text(source))
      end

      private def crystal_declaration(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, names : Array(String), modules : Array(String), kind : String, name : String, visibility : String?, extraction_method : String = "tree_sitter_ast") : Declaration
        qualified_name = (names + [name]).join(".")
        namespace = modules.empty? ? nil : modules.join(".")
        owner = names.empty? ? nil : names.join(".")
        parameters = crystal_parameters(node, source)
        return_type = crystal_named_field(node, "type").try(&.text(source))
        overload_key = parameters.try { |items| "(#{items.map { |item| item.type_name || "?" }.join(",")})" }
        legacy_kind = crystal_legacy_kind(kind, node)
        Declaration.new(
          language: "crystal", namespace: namespace, owner: owner, kind: kind, name: name,
          qualified_name: qualified_name, file: file_path, span: Span.from_node(node),
          ast_node_type: node.type, extraction_method: extraction_method,
          parameters: parameters, return_type: return_type,
          signature: java_signature(parameters, return_type),
          visibility: visibility || "public", static: kind == "field" ? name.starts_with?("@@") : crystal_class_method?(node),
          abstract: node.type == "abstract_method_def" ? true : nil,
          mutable: kind == "constant" || kind == "enum_member" ? false : (kind == "field" ? true : nil),
          legacy_aliases: ["#{file_path}::#{legacy_kind}::#{qualified_name}"],
          declaration_id: DeclarationIdentity.declaration_id(DeclarationIdentityInput.new(
            language: "crystal", namespace: namespace, owner_chain: names[modules.size..],
            kind: kind, name: name, overload_key: overload_key,
          )),
          occurrence_id: occurrence_id(logical_path, node),
        )
      end

      private def crystal_parameters(node : TreeSitter::Node, source : String) : Array(Parameter)?
        list = node.child_by_field_name("params")
        return nil unless list
        list.children.compact_map do |child|
          next unless child.type.in?("param", "splat_param", "double_splat_param")
          name = child.child_by_field_name("name").try(&.text(source))
          next unless name
          Parameter.new(name: name, type_name: crystal_named_field(child, "type").try(&.text(source)), variadic: child.type != "param")
        end.to_a
      end

      private def crystal_named_field(node : TreeSitter::Node, field : String) : TreeSitter::Node?
        selected = nil.as(TreeSitter::Node?)
        node.children.to_a.each_with_index do |child, index|
          selected = child if child.named? && node.field_name_for_child(index.to_u32) == field
        end
        selected
      end

      private def crystal_class_method?(node : TreeSitter::Node) : Bool?
        return nil unless node.type.in?("method_def", "abstract_method_def")
        node.children.any?(&.type.==("self"))
      end

      private def crystal_legacy_kind(kind : String, node : TreeSitter::Node) : String
        case kind
        when "module"                                       then "interface"
        when "struct", "union", "c_struct"                  then "class"
        when "enum", "type_alias", "type_def", "annotation" then "type"
        when "constant", "enum_member"                      then "variable"
        when "method"                                       then crystal_class_method?(node) ? "method" : "function"
        else                                                     kind
        end
      end
    end
  end
end
