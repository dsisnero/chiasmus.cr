require "json"
require "tree_sitter"
require "./span"
require "./types"
require "./declaration_identity"

module Chiasmus
  module Graph
    # Structured declarations produced during the same tree walk as the legacy
    # graph and discovery projections. Unknown fields remain nil, not false.
    module FileExtraction
      struct Parameter
        include JSON::Serializable

        getter name : String
        getter type_name : String? = nil
        getter? variadic : Bool = false

        def initialize(@name : String, @type_name : String? = nil, @variadic : Bool = false)
        end
      end

      struct Declaration
        include JSON::Serializable

        getter language : String
        getter namespace : String?
        getter owner : String?
        getter kind : String
        getter name : String
        getter qualified_name : String
        getter file : String
        getter span : Span
        getter ast_node_type : String?
        getter extraction_method : String
        getter signature : String? = nil
        getter parameters : Array(Parameter)? = nil
        getter return_type : String? = nil
        getter visibility : String? = nil
        getter static : Bool? = nil
        getter abstract : Bool? = nil
        getter mutable : Bool? = nil
        getter base_types : Array(String)? = nil
        getter legacy_aliases : Array(String) = [] of String
        getter declaration_id : String? = nil
        getter occurrence_id : String? = nil

        def initialize(
          @language : String,
          @namespace : String?,
          @owner : String?,
          @kind : String,
          @name : String,
          @qualified_name : String,
          @file : String,
          @span : Span,
          @ast_node_type : String?,
          @extraction_method : String,
          @signature : String? = nil,
          @parameters : Array(Parameter)? = nil,
          @return_type : String? = nil,
          @visibility : String? = nil,
          @static : Bool? = nil,
          @abstract : Bool? = nil,
          @mutable : Bool? = nil,
          @base_types : Array(String)? = nil,
          @legacy_aliases : Array(String) = [] of String,
          @declaration_id : String? = nil,
          @occurrence_id : String? = nil,
        )
        end
      end

      struct Result
        include JSON::Serializable

        getter declarations : Array(Declaration)

        def initialize(@declarations : Array(Declaration))
        end

        def relocate(from_path : String, to_path : String) : self
          return self if from_path == to_path

          Result.new(@declarations.map do |declaration|
            next declaration unless declaration.file == from_path
            aliases = declaration.legacy_aliases.map do |alias_id|
              alias_id.starts_with?("#{from_path}::") ? alias_id.sub(/^#{Regex.escape(from_path)}::/, "#{to_path}::") : alias_id
            end
            Declaration.new(
              language: declaration.language,
              namespace: declaration.namespace,
              owner: declaration.owner,
              kind: declaration.kind,
              name: declaration.name,
              qualified_name: declaration.qualified_name,
              file: to_path,
              span: declaration.span,
              ast_node_type: declaration.ast_node_type,
              extraction_method: declaration.extraction_method,
              signature: declaration.signature,
              parameters: declaration.parameters,
              return_type: declaration.return_type,
              visibility: declaration.visibility,
              static: declaration.static,
              abstract: declaration.abstract,
              mutable: declaration.mutable,
              base_types: declaration.base_types,
              legacy_aliases: aliases,
              declaration_id: declaration.declaration_id,
              occurrence_id: declaration.occurrence_id,
            )
          end)
        end
      end

      extend self

      def extract(language : String, tree : TreeSitter::Tree, source : String, file_path : String, graph : CodeGraph, logical_path : String? = nil) : Result
        declarations = if language == "java"
                         java_declarations(tree.root_node, source, file_path, logical_path)
                       elsif language == "go"
                         go_declarations(tree.root_node, source, file_path, logical_path)
                       else
                         graph.defines.map do |definition|
                           name = definition.qualified_name || definition.name
                           Declaration.new(
                             language: language,
                             namespace: nil,
                             owner: nil,
                             kind: definition.kind.to_prolog_atom,
                             name: definition.name,
                             qualified_name: name,
                             file: definition.file,
                             span: definition.span,
                             ast_node_type: nil,
                             extraction_method: "legacy_graph",
                             signature: definition.signature,
                             legacy_aliases: ["#{definition.file}::#{definition.kind.to_prolog_atom}::#{name}"],
                           )
                         end
                       end
        tree.root_node
        Result.new(declarations)
      end

      private def java_declarations(root : TreeSitter::Node, source : String, file_path : String, logical_path : String?) : Array(Declaration)
        declarations = [] of Declaration
        namespace = java_namespace(root, source)
        walk_java(root, source, file_path, logical_path, namespace, [] of String, declarations)
        declarations
      end

      private def java_namespace(root : TreeSitter::Node, source : String) : String?
        package = root.children.find(&.type.==("package_declaration"))
        package.try { |node| node.text(source).sub(/^package\s+/, "").sub(/;\s*$/, "").strip }
      end

      private def walk_java(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, namespace : String?, owners : Array(String), declarations : Array(Declaration)) : Nil
        kind = java_kind(node.type)
        if kind && (name_node = node.child_by_field_name("name"))
          name = name_node.text(source)
          declarations << java_declaration(node, source, file_path, logical_path, namespace, owners, kind, name)
          if kind.in?("class", "interface", "enum", "record")
            owners = owners + [name]
          end
        elsif node.type.in?("field_declaration", "constant_declaration")
          java_field_declarations(node, source, file_path, logical_path, namespace, owners, declarations)
        end

        node.children.each do |child|
          walk_java(child, source, file_path, logical_path, namespace, owners, declarations)
        end
      end

      private def java_kind(node_type : String) : String?
        case node_type
        when "class_declaration"       then "class"
        when "interface_declaration"   then "interface"
        when "enum_declaration"        then "enum"
        when "record_declaration"      then "record"
        when "method_declaration"      then "method"
        when "constructor_declaration" then "constructor"
        when "enum_constant"           then "enum_constant"
        end
      end

      private def java_declaration(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, namespace : String?, owners : Array(String), kind : String, name : String) : Declaration
        qualified_name = (owners + [name]).join(".")
        parameters = node.child_by_field_name("parameters").try { |params| java_parameters(params, source) }
        return_type = node.child_by_field_name("type").try(&.text(source))
        signature = java_signature(parameters, return_type)
        modifiers = java_modifiers(node, source)
        Declaration.new(
          language: "java", namespace: namespace, owner: owners.empty? ? nil : owners.join("."), kind: kind,
          name: name, qualified_name: qualified_name, file: file_path, span: Span.from_node(node),
          ast_node_type: node.type, extraction_method: "tree_sitter_ast", signature: signature,
          parameters: parameters, return_type: return_type,
          visibility: java_visibility(modifiers, implicit_public: java_implicit_public?(node, kind)),
          static: java_static?(modifiers, kind), abstract: java_abstract?(node, modifiers, kind),
          base_types: java_declaration_bases(node, source, kind),
          legacy_aliases: ["#{file_path}::#{java_legacy_kind(kind)}::#{qualified_name}"],
          declaration_id: declaration_id(namespace, owners, kind, name, parameters),
          occurrence_id: occurrence_id(logical_path, node),
        )
      end

      private def java_signature(parameters : Array(Parameter)?, return_type : String?) : String?
        return nil unless parameters
        signature = "(#{parameters.map { |param| "#{param.type_name} #{param.name}".strip }.join(", ")})"
        return_type ? "#{signature} -> #{return_type}" : signature
      end

      private def java_implicit_public?(node : TreeSitter::Node, kind : String) : Bool
        node.parent.try(&.type) == "interface_body" || kind == "enum_constant"
      end

      private def java_static?(modifiers : Set(String), kind : String) : Bool
        modifiers.includes?("static") || kind == "enum_constant"
      end

      private def java_abstract?(node : TreeSitter::Node, modifiers : Set(String), kind : String) : Bool
        return true if modifiers.includes?("abstract")
        node.parent.try(&.type) == "interface_body" && kind == "method" &&
          !modifiers.includes?("default") && !modifiers.includes?("static") && !modifiers.includes?("private")
      end

      private def java_declaration_bases(node : TreeSitter::Node, source : String, kind : String) : Array(String)?
        return nil unless kind.in?("class", "interface", "record")
        java_base_types(node, source)
      end

      private def java_legacy_kind(kind : String) : String
        return "class" if kind.in?("enum", "record")
        return "variable" if kind == "enum_constant"
        kind
      end

      private def java_parameters(node : TreeSitter::Node, source : String) : Array(Parameter)
        node.children.compact_map do |child|
          next unless child.type.in?("formal_parameter", "spread_parameter", "receiver_parameter")
          name = child.child_by_field_name("name").try(&.text(source))
          next unless name
          Parameter.new(name: name, type_name: child.child_by_field_name("type").try(&.text(source)), variadic: child.type == "spread_parameter")
        end.to_a
      end

      private def java_modifiers(node : TreeSitter::Node, source : String) : Set(String)
        modifiers = node.children.find(&.type.==("modifiers"))
        return Set(String).new unless modifiers
        modifiers.text(source).scan(/\b(?:public|protected|private|static|abstract|final|default)\b/).map(&.[0]).to_set
      end

      private def java_base_types(node : TreeSitter::Node, source : String) : Array(String)
        node.children.select { |child| child.type.in?("superclass", "super_interfaces", "extends_interfaces") }
          .map(&.text(source)).to_a
      end

      private def java_field_declarations(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, namespace : String?, owners : Array(String), declarations : Array(Declaration)) : Nil
        type_name = node.child_by_field_name("type").try(&.text(source))
        modifiers = java_modifiers(node, source)
        interface_member = node.parent.try(&.type) == "interface_body"
        node.children.each do |child|
          next unless child.type == "variable_declarator"
          name = child.child_by_field_name("name").try(&.text(source))
          next unless name
          static = modifiers.includes?("static") || interface_member
          final = modifiers.includes?("final") || interface_member
          kind = static && final ? "constant" : "field"
          qualified_name = (owners + [name]).join(".")
          declarations << Declaration.new(
            language: "java", namespace: namespace, owner: owners.empty? ? nil : owners.join("."),
            kind: kind, name: name, qualified_name: qualified_name, file: file_path,
            span: Span.from_node(child), ast_node_type: child.type, extraction_method: "tree_sitter_ast",
            return_type: type_name, static: static, mutable: !final,
            visibility: java_visibility(modifiers, implicit_public: interface_member),
            legacy_aliases: ["#{file_path}::#{kind == "constant" ? "const" : "field"}::#{qualified_name}"],
            declaration_id: declaration_id(namespace, owners, kind, name, nil),
            occurrence_id: occurrence_id(logical_path, child),
          )
        end
      end

      private def java_visibility(modifiers : Set(String), implicit_public : Bool = false) : String
        return "public" if modifiers.includes?("public")
        return "protected" if modifiers.includes?("protected")
        return "private" if modifiers.includes?("private")
        return "public" if implicit_public
        "package"
      end

      private def declaration_id(namespace : String?, owners : Array(String), kind : String, name : String, parameters : Array(Parameter)?) : String
        overload_key = parameters.try { |items| "(#{items.map { |item| item.type_name || "?" }.join(",")})" }
        DeclarationIdentity.declaration_id(DeclarationIdentityInput.new(
          language: "java", namespace: namespace, owner_chain: owners,
          kind: kind, name: name, overload_key: overload_key,
        ))
      end

      private def occurrence_id(logical_path : String?, node : TreeSitter::Node) : String?
        return nil unless logical_path
        DeclarationIdentity.occurrence_id(OccurrenceIdentityInput.new(logical_path, Span.from_node(node), node.type))
      end

      private def go_declarations(root : TreeSitter::Node, source : String, file_path : String, logical_path : String?) : Array(Declaration)
        declarations = [] of Declaration
        namespace = root.children.find(&.type.==("package_clause")).try do |package|
          package.children.find(&.type.==("package_identifier")).try(&.text(source))
        end
        root.children.each do |node|
          case node.type
          when "const_declaration"
            go_walk_specs(node, "const_spec") do |spec|
              go_named_nodes(spec, "name").each do |name_node|
                declarations << go_simple_declaration(name_node, spec, source, file_path, logical_path, namespace, "constant")
              end
            end
          when "var_declaration"
            go_walk_specs(node, "var_spec") do |spec|
              go_named_nodes(spec, "name").each do |name_node|
                declarations << go_simple_declaration(name_node, spec, source, file_path, logical_path, namespace, "variable")
              end
            end
          when "type_declaration"
            go_walk_specs(node, "type_spec") do |spec|
              type_node = spec.child_by_field_name("type")
              next unless type_node
              kind = case type_node.type
                     when "interface_type" then "interface"
                     when "struct_type"    then "class"
                     else                       "defined_type"
                     end
              go_named_nodes(spec, "name").each do |name_node|
                declarations << go_simple_declaration(name_node, spec, source, file_path, logical_path, namespace, kind)
                if type_node.type == "struct_type"
                  go_walk_specs(type_node, "field_declaration") do |field|
                    go_named_nodes(field, "name").each do |field_name|
                      declarations << go_field_declaration(field_name, field, name_node.text(source), source, file_path, logical_path, namespace)
                    end
                  end
                end
              end
            end
            go_walk_specs(node, "type_alias") do |spec|
              go_named_nodes(spec, "name").each do |name_node|
                declarations << go_simple_declaration(name_node, spec, source, file_path, logical_path, namespace, "type_alias")
              end
            end
          when "function_declaration", "method_declaration"
            if declaration = go_callable_declaration(node, source, file_path, logical_path, namespace)
              declarations << declaration
            end
          end
        end
        declarations
      end

      private def go_walk_specs(node : TreeSitter::Node, spec_type : String, &block : TreeSitter::Node ->) : Nil
        node.children.each do |child|
          if child.type == spec_type
            yield child
          else
            go_walk_specs(child, spec_type, &block)
          end
        end
      end

      private def go_named_nodes(node : TreeSitter::Node, field : String) : Array(TreeSitter::Node)
        if node.type.in?("const_spec", "var_spec", "parameter_declaration", "field_declaration")
          name_type = node.type == "field_declaration" ? "field_identifier" : "identifier"
          names = [] of TreeSitter::Node
          node.children.each do |child|
            if child.type == name_type
              names << child
            elsif child.type != ","
              break
            end
          end
          return names
        end
        if name = node.child_by_field_name(field)
          return name.type == "identifier_list" ? name.children.select(&.named?).to_a : [name]
        end
        node.children.select { |child| child.type.in?("identifier", "type_identifier", "field_identifier") }.to_a
      end

      private def go_simple_declaration(name_node : TreeSitter::Node, spec : TreeSitter::Node, source : String, file_path : String, logical_path : String?, namespace : String?, kind : String) : Declaration
        name = name_node.text(source)
        type_name = spec.child_by_field_name("type").try(&.text(source))
        legacy_kind = case kind
                      when "constant"                   then "const"
                      when "defined_type", "type_alias" then "class"
                      else                                   kind
                      end
        Declaration.new(
          language: "go", namespace: namespace, owner: nil, kind: kind, name: name,
          qualified_name: name, file: file_path, span: Span.from_node(spec),
          ast_node_type: spec.type, extraction_method: "tree_sitter_ast",
          return_type: type_name, visibility: go_visibility(name),
          mutable: kind == "constant" ? false : (kind == "variable" ? true : nil),
          legacy_aliases: ["#{file_path}::#{legacy_kind}::#{name}"],
          declaration_id: go_declaration_id(namespace, nil, kind, name, nil),
          occurrence_id: occurrence_id(logical_path, name_node),
        )
      end

      private def go_field_declaration(name_node : TreeSitter::Node, field : TreeSitter::Node, owner : String, source : String, file_path : String, logical_path : String?, namespace : String?) : Declaration
        name = name_node.text(source)
        Declaration.new(
          language: "go", namespace: namespace, owner: owner, kind: "field", name: name,
          qualified_name: "#{owner}.#{name}", file: file_path, span: Span.from_node(field),
          ast_node_type: field.type, extraction_method: "tree_sitter_ast",
          return_type: field.child_by_field_name("type").try(&.text(source)),
          visibility: go_visibility(name), mutable: true,
          legacy_aliases: ["#{file_path}::field::#{owner}.#{name}"],
          declaration_id: go_declaration_id(namespace, owner, "field", name, nil),
          occurrence_id: occurrence_id(logical_path, name_node),
        )
      end

      private def go_callable_declaration(node : TreeSitter::Node, source : String, file_path : String, logical_path : String?, namespace : String?) : Declaration?
        name_node = node.child_by_field_name("name")
        return nil unless name_node
        name = name_node.text(source)
        kind = node.type == "method_declaration" ? "method" : "function"
        owner = go_receiver_owner(node.child_by_field_name("receiver"), source)
        qualified_name = owner ? "#{owner}.#{name}" : name
        parameters = node.child_by_field_name("parameters").try { |list| go_parameters(list, source) }
        return_type = node.child_by_field_name("result").try(&.text(source))
        Declaration.new(
          language: "go", namespace: namespace, owner: owner, kind: kind, name: name,
          qualified_name: qualified_name, file: file_path, span: Span.from_node(node),
          ast_node_type: node.type, extraction_method: "tree_sitter_ast",
          parameters: parameters, return_type: return_type, signature: java_signature(parameters, return_type),
          visibility: go_visibility(name),
          legacy_aliases: ["#{file_path}::#{kind}::#{qualified_name}"],
          declaration_id: go_declaration_id(namespace, owner, kind, name, parameters),
          occurrence_id: occurrence_id(logical_path, node),
        )
      end

      private def go_receiver_owner(receiver : TreeSitter::Node?, source : String) : String?
        return nil unless receiver
        parameter = receiver.children.find(&.type.==("parameter_declaration"))
        type_name = parameter.try(&.child_by_field_name("type")).try(&.text(source))
        type_name.try(&.lchop('*').split('[').first)
      end

      private def go_parameters(list : TreeSitter::Node, source : String) : Array(Parameter)
        list.children.flat_map do |child|
          next [] of Parameter unless child.type.in?("parameter_declaration", "variadic_parameter_declaration")
          type_name = child.child_by_field_name("type").try(&.text(source))
          names = go_named_nodes(child, "name")
          names = [child] if names.empty?
          names.map do |name_node|
            name = name_node == child ? "_" : name_node.text(source)
            Parameter.new(name: name, type_name: type_name, variadic: child.type == "variadic_parameter_declaration")
          end
        end.to_a
      end

      private def go_visibility(name : String) : String
        name.matches?(/^[A-Z]/) ? "public" : "package"
      end

      private def go_declaration_id(namespace : String?, owner : String?, kind : String, name : String, parameters : Array(Parameter)?) : String
        overload_key = parameters.try { |items| "(#{items.map { |item| item.type_name || "?" }.join(",")})" }
        DeclarationIdentity.declaration_id(DeclarationIdentityInput.new(
          language: "go", namespace: namespace, owner_chain: owner ? [owner] : [] of String,
          kind: kind, name: name, overload_key: overload_key,
        ))
      end
    end
  end
end
