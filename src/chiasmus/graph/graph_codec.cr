require "json"
require "./types"

module Chiasmus
  module Graph
    # Stable wire representation shared by cache backends and snapshots.
    module GraphCodec
      extend self

      struct Definition
        include JSON::Serializable

        getter file : String
        getter name : String
        getter kind : String
        getter span : Span
        getter signature : String? = nil
        getter qualified_name : String? = nil

        def initialize(@file, @name, @kind, @span, @signature = nil, @qualified_name = nil)
        end
      end

      struct Call
        include JSON::Serializable

        getter caller : String
        getter callee : String
        getter callee_qn : String? = nil
        getter caller_qn : String? = nil

        def initialize(@caller, @callee, @callee_qn = nil, @caller_qn = nil)
        end
      end

      struct Import
        include JSON::Serializable

        getter file : String
        getter name : String
        getter source : String

        def initialize(@file, @name, @source)
        end
      end

      struct Export
        include JSON::Serializable

        getter file : String
        getter name : String

        def initialize(@file, @name)
        end
      end

      struct Containment
        include JSON::Serializable

        getter parent : String
        getter child : String

        def initialize(@parent, @child)
        end
      end

      struct FileEntry
        include JSON::Serializable

        getter path : String
        getter language : String
        getter line_count : Int32? = nil
        getter token_estimate : Int32? = nil
        getter file_doc : String? = nil

        def initialize(@path, @language, @line_count = nil, @token_estimate = nil, @file_doc = nil)
        end
      end

      struct ClassField
        include JSON::Serializable

        getter class_name : String
        getter fields : Hash(String, String) = Hash(String, String).new

        def initialize(@class_name, @fields = Hash(String, String).new)
        end
      end

      struct ClassMethod
        include JSON::Serializable

        getter class_name : String
        getter methods : Array(String) = [] of String

        def initialize(@class_name, @methods = [] of String)
        end
      end

      struct ClassInheritance
        include JSON::Serializable

        getter class_name : String
        getter parent : String

        def initialize(@class_name, @parent)
        end
      end

      struct Pending
        include JSON::Serializable

        getter caller : String
        getter callee : String
        getter receiver_chain : Array(String) = [] of String
        getter enclosing_class : String? = nil
        getter var_types : Hash(String, String) = Hash(String, String).new

        def initialize(@caller, @callee, @receiver_chain = [] of String, @enclosing_class = nil, @var_types = Hash(String, String).new)
        end
      end

      struct TypeInfo
        include JSON::Serializable

        getter file : String
        getter class_fields : Array(ClassField) = [] of ClassField
        getter class_methods : Array(ClassMethod)? = nil
        getter class_extends : Array(ClassInheritance)? = nil
        getter pending_calls : Array(Pending) = [] of Pending

        def initialize(
          @file,
          @class_fields = [] of ClassField,
          @class_methods = nil,
          @class_extends = nil,
          @pending_calls = [] of Pending,
        )
        end
      end

      struct Document
        include JSON::Serializable

        getter defines : Array(Definition) = [] of Definition
        getter calls : Array(Call) = [] of Call
        getter imports : Array(Import) = [] of Import
        getter exports : Array(Export) = [] of Export
        getter contains : Array(Containment) = [] of Containment
        getter files : Array(FileEntry)? = nil

        @[JSON::Field(key: "_typeInfo")]
        getter type_info : Array(TypeInfo)? = nil

        def initialize(
          @defines = [] of Definition,
          @calls = [] of Call,
          @imports = [] of Import,
          @exports = [] of Export,
          @contains = [] of Containment,
          @files = nil,
          @type_info = nil,
        )
        end
      end

      def encode(graph : CodeGraph) : String
        from_domain(graph).to_json
      end

      def decode(raw : String) : CodeGraph
        to_domain(Document.from_json(raw))
      end

      private def from_domain(graph : CodeGraph) : Document
        Document.new(
          defines: graph.defines.map { |definition|
            Definition.new(
              definition.file,
              definition.name,
              definition.kind.to_s,
              definition.span,
              definition.signature,
              definition.qualified_name
            )
          },
          calls: graph.calls.map { |call| Call.new(call.caller, call.callee, call.callee_qn, call.caller_qn) },
          imports: graph.imports.map { |import| Import.new(import.file, import.name, import.source) },
          exports: graph.exports.map { |export| Export.new(export.file, export.name) },
          contains: graph.contains.map { |containment| Containment.new(containment.parent, containment.child) },
          files: graph.files.try(&.map { |file| FileEntry.new(file.path, file.language, file.line_count, file.token_estimate, file.file_doc) }),
          type_info: graph.type_info.try(&.map { |entry|
            TypeInfo.new(
              file: entry.file,
              class_fields: entry.class_fields.map { |field| ClassField.new(field.class_name, field.fields) },
              class_methods: entry.class_methods.try(&.map { |method| ClassMethod.new(method.class_name, method.methods) }),
              class_extends: entry.class_extends.try(&.map { |inheritance| ClassInheritance.new(inheritance.class_name, inheritance.parent) }),
              pending_calls: entry.pending_calls.map { |pending|
                Pending.new(pending.caller, pending.callee, pending.receiver_chain, pending.enclosing_class, pending.var_types)
              }
            )
          })
        )
      end

      private def to_domain(document : Document) : CodeGraph
        CodeGraph.new(
          defines: document.defines.map { |definition|
            DefinesFact.new(
              file: definition.file,
              name: definition.name,
              kind: SymbolKind.parse(definition.kind),
              span: definition.span,
              signature: definition.signature,
              qualified_name: definition.qualified_name
            )
          },
          calls: document.calls.map { |call| CallsFact.new(call.caller, call.callee, call.callee_qn, call.caller_qn) },
          imports: document.imports.map { |import| ImportsFact.new(import.file, import.name, import.source) },
          exports: document.exports.map { |export| ExportsFact.new(export.file, export.name) },
          contains: document.contains.map { |containment| ContainsFact.new(containment.parent, containment.child) },
          files: document.files.try(&.map { |file| FileNode.new(file.path, file.language, file.line_count, file.token_estimate, file.file_doc) }),
          type_info: document.type_info.try(&.map { |entry|
            FileTypeInfo.new(
              file: entry.file,
              class_fields: entry.class_fields.map { |field| ClassFieldEntry.new(field.class_name, field.fields) },
              class_methods: entry.class_methods.try(&.map { |method| ClassMethodEntry.new(method.class_name, method.methods) }),
              class_extends: entry.class_extends.try(&.map { |inheritance| ClassExtendsEntry.new(inheritance.class_name, inheritance.parent) }),
              pending_calls: entry.pending_calls.map { |pending|
                PendingCall.new(pending.caller, pending.callee, pending.receiver_chain, pending.enclosing_class, pending.var_types)
              }
            )
          })
        )
      end
    end
  end
end
