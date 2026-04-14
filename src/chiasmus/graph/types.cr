require "tree_sitter"

module Chiasmus
  module Graph
    enum SymbolKind
      Function
      Method
      Class
      Interface
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
      callee : String

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

    record CodeGraph,
      defines : Array(DefinesFact) = [] of DefinesFact,
      calls : Array(CallsFact) = [] of CallsFact,
      imports : Array(ImportsFact) = [] of ImportsFact,
      exports : Array(ExportsFact) = [] of ExportsFact,
      contains : Array(ContainsFact) = [] of ContainsFact

    abstract class LanguageAdapter
      abstract def language : String
      abstract def extensions : Array(String)
      abstract def extract(root_node : TreeSitter::Node, file_path : String) : CodeGraph

      def search_paths : Array(String)?
        nil
      end
    end
  end
end
