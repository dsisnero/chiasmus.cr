require "tree_sitter"

module Chiasmus
  module Graph
    enum SymbolKind
      Function
      Method
      Class
      Interface
      Type
      Variable

      def to_prolog_atom : String
        to_s.downcase
      end
    end

    record DefinesFact,
      file : String,
      name : String,
      kind : SymbolKind,
      line : Int32

    record CallsFact,
      caller : String,
      callee : String,
      callee_qn : String? = nil

    record ImportsFact,
      file : String,
      name : String,
      source : String

    record ExportsFact,
      file : String,
      name : String

    record ContainsFact,
      parent : String,
      child : String

    # Per-file type info for 2-pass QN resolution (resolve-calls).
    record PendingCall,
      caller : String,
      callee : String,
      receiver_chain : Array(String) = [] of String,
      enclosing_class : String? = nil,
      var_types : Hash(String, String) = Hash(String, String).new

    record ClassFieldEntry,
      class_name : String,
      fields : Hash(String, String) = Hash(String, String).new

    record ClassMethodEntry,
      class_name : String,
      methods : Array(String) = [] of String

    record ClassExtendsEntry,
      class_name : String,
      parent : String

    record FileTypeInfo,
      file : String,
      class_fields : Array(ClassFieldEntry) = [] of ClassFieldEntry,
      class_methods : Array(ClassMethodEntry)? = nil,
      class_extends : Array(ClassExtendsEntry)? = nil,
      pending_calls : Array(PendingCall) = [] of PendingCall

    # Project-wide class method registry from resolve-calls.
    record ClassMethodRegistry,
      flat : Hash(String, Set(String)),
      own : Hash(String, Set(String)),
      parents : Hash(String, String)

    record CodeGraph,
      defines : Array(DefinesFact) = [] of DefinesFact,
      calls : Array(CallsFact) = [] of CallsFact,
      imports : Array(ImportsFact) = [] of ImportsFact,
      exports : Array(ExportsFact) = [] of ExportsFact,
      contains : Array(ContainsFact) = [] of ContainsFact,
      type_info : Array(FileTypeInfo)? = nil

    abstract class LanguageAdapter
      abstract def language : String
      abstract def extensions : Array(String)
      abstract def extract(root_node : TreeSitter::Node, source : String, file_path : String) : CodeGraph

      def grammar_language : String
        language
      end

      def search_paths : Array(String)?
        nil
      end
    end

    record AdapterDescriptor,
      language : String,
      extensions : Array(String),
      grammar_language : String,
      entrypoint : String,
      search_paths : Array(String)? = nil

    abstract class AdapterFactory
      abstract def build(descriptor : AdapterDescriptor) : LanguageAdapter?
    end
  end
end
