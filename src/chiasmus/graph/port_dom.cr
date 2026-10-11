require "./ir"
require "./types"

module Chiasmus
  module Graph
    # PortDOM: a typed, language-neutral view of a code graph's API surface,
    # layered above `IR::SemanticGraph`. It models types, methods, and
    # properties (parameters, return types, visibility, base types) so parity
    # can compare structure above the call-graph level. P0 adds the schema and a
    # lossless round-trip; surface population from signatures is P1+.
    #
    # See `plans/port_dom.md` and `docs/parity-rule-data.md`.
    module PortDom
      enum Visibility
        Public
        Protected
        Private
      end

      enum ParamKind
        Positional
        Named
        Block
        Receiver
        Kwarg
      end

      enum SurfaceKind
        Class
        Struct
        Module
        Interface
        Enum
        Alias
        Lib
        Unknown
      end

      record TypeRef,
        name : String,
        nullable : Bool = false,
        generic_args : Array(String) = [] of String

      record Param,
        name : String,
        type : TypeRef? = nil,
        default : String? = nil,
        variadic : Bool = false,
        kind : ParamKind = ParamKind::Positional

      record MethodSurface,
        symbol_id : String,
        name : String,
        params : Array(Param) = [] of Param,
        return_type : TypeRef? = nil,
        raises : Array(String) = [] of String,
        static : Bool = false,
        abstract : Bool = false,
        visibility : Visibility = Visibility::Public

      record PropertySurface,
        symbol_id : String,
        name : String,
        type : TypeRef? = nil,
        mutable : Bool = false,
        visibility : Visibility = Visibility::Public

      record TypeSurface,
        symbol_id : String,
        kind : SurfaceKind,
        base_types : Array(String) = [] of String,
        type_params : Array(String) = [] of String,
        visibility : Visibility = Visibility::Public

      record PortDom,
        graph : IR::SemanticGraph,
        types : Array(TypeSurface) = [] of TypeSurface,
        methods : Array(MethodSurface) = [] of MethodSurface,
        properties : Array(PropertySurface) = [] of PropertySurface do
        def symbols : Array(IR::SymbolNode)
          graph.symbols
        end

        def to_semantic_graph : IR::SemanticGraph
          graph
        end

        def to_code_graph : CodeGraph
          IR::Lowering.to_code_graph(graph)
        end
      end

      extend self

      # Lowers a `CodeGraph` into the semantic IR and classifies each symbol into
      # a surface record. Uses the O(n) `Lowering.from_code_graph` (not the full
      # refiner pipeline) so building surfaces over large graphs stays cheap.
      def build(graph : CodeGraph) : PortDom
        build(IR::Lowering.from_code_graph(graph))
      end

      def build(graph : IR::SemanticGraph) : PortDom
        types = [] of TypeSurface
        methods = [] of MethodSurface
        properties = [] of PropertySurface

        graph.symbols.each do |symbol|
          case symbol.kind
          when .class?, .interface?, .module?, .type?
            types << TypeSurface.new(symbol_id: symbol.id, kind: surface_kind(symbol.kind))
          when .method?, .function?
            params, return_type = parse_signature(symbol.signature)
            methods << MethodSurface.new(symbol_id: symbol.id, name: symbol.name, params: params, return_type: return_type)
          when .variable?
            properties << PropertySurface.new(symbol_id: symbol.id, name: symbol.name)
          end
        end

        PortDom.new(graph: graph, types: types, methods: methods, properties: properties)
      end

      # Parses a method signature string into parameters and a return type.
      #
      # Supported shape (as emitted by the walkers that populate signatures,
      # e.g. Rust): `(a: i32, b: &str) -> Result<(), Error>`. Parameters without
      # an explicit return use `(a: i32, b: &str)`. Unparseable input yields an
      # empty surface rather than a guess.
      def parse_signature(signature : String?) : Tuple(Array(Param), TypeRef?)
        return {[] of Param, nil} unless signature

        text = signature.strip
        return {[] of Param, nil} if text.empty?

        params_text = text
        return_type = nil
        if arrow = top_level_index(text, "->")
          params_text = text[0...arrow].strip
          return_text = text[(arrow + 2)..].strip
          return_type = type_ref(return_text) unless return_text.empty?
        end

        params_text = params_text.strip
        if params_text.starts_with?('(') && params_text.ends_with?(')')
          params_text = params_text[1...-1]
        end

        params = split_top_level(params_text, ',').compact_map { |piece| parse_param(piece) }
        {params, return_type}
      end

      private def parse_param(text : String) : Param?
        piece = text.strip
        return nil if piece.empty?

        variadic = piece.ends_with?("...")
        piece = piece.rchop("...").strip if variadic

        default = nil
        if equals = top_level_index(piece, "=")
          default = piece[(equals + 1)..].strip
          piece = piece[0...equals].strip
        end

        name : String
        type_name : String?
        if colon = top_level_index(piece, ":")
          name = piece[0...colon].strip
          type_name = piece[(colon + 1)..].strip
        else
          tokens = piece.split(/\s+/)
          if tokens.size >= 2
            # Java-style `Type name`: the type is everything but the trailing
            # identifier.
            name = tokens.last
            type_name = tokens[0...-1].join(" ")
          elsif token = tokens.first?
            # A single token is a param name (`self`) unless it looks like a
            # type (starts uppercase).
            if token[0]?.try(&.uppercase?)
              name = ""
              type_name = token
            else
              name = token
              type_name = nil
            end
          else
            name = ""
            type_name = nil
          end
        end

        return nil if name.empty? && type_name.nil?

        Param.new(
          name: name,
          type: type_name.try { |value| type_ref(value) },
          default: default,
          variadic: variadic,
        )
      end

      private def type_ref(text : String) : TypeRef
        name = text.strip
        nullable = name.ends_with?('?')
        name = name.rchop('?').strip if nullable
        TypeRef.new(name: name, nullable: nullable)
      end

      # Index of `needle` at bracket depth zero (outside `()`, `<>`, `[]`, `{}`).
      private def top_level_index(text : String, needle : String) : Int32?
        depth = 0
        index = 0
        while index <= text.size - needle.size
          char = text[index]
          case char
          when '(', '<', '[', '{' then depth += 1
          when ')', '>', ']', '}' then depth -= 1
          end
          return index if depth.zero? && text[index, needle.size] == needle
          index += 1
        end
        nil
      end

      private def split_top_level(text : String, separator : Char) : Array(String)
        return [] of String if text.strip.empty?

        pieces = [] of String
        depth = 0
        current = String::Builder.new
        text.each_char do |char|
          case char
          when '(', '<', '[', '{' then depth += 1
          when ')', '>', ']', '}' then depth -= 1
          end
          if depth.zero? && char == separator
            pieces << current.to_s
            current = String::Builder.new
          else
            current << char
          end
        end
        pieces << current.to_s
        pieces
      end

      def surface_kind(kind : SymbolKind) : SurfaceKind
        case kind
        in .class?              then SurfaceKind::Class
        in .interface?          then SurfaceKind::Interface
        in .module?             then SurfaceKind::Module
        in .type?               then SurfaceKind::Alias
        in .method?, .function? then SurfaceKind::Unknown
        in .variable?           then SurfaceKind::Unknown
        end
      end
    end
  end
end
