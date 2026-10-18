require "option_parser"
require "set"
require "./discovery"
require "./graph/facts_snapshot"
require "./graph/ir"
require "./graph/parallel_io"
require "./graph/types"
require "./utils/bounded_work"
require "./utils/config"
require "./index/directory_walk"
require "./parity/naming"
require "./parity/rules"
require "./parity/reconcile"
require "./parity/port_concepts"
require "./parity/bundle_cache"
require "./parity/surface"

module Chiasmus
  module Parity
    VALID_CANDIDATE_KINDS = Set{
      "annotation",
      "class",
      "const",
      "enum",
      "function",
      "interface",
      "lib",
      "macro",
      "method",
      "test",
      "type",
    }

    MAX_CONCURRENCY = Math.max(System.cpu_count, 2).to_i32

    record InventoryRow,
      source_id : String,
      kind : String,
      status : String,
      crystal_refs : String,
      notes : String,
      target_symbol : String = "",
      test_refs : String = "" do
      def source_file : String?
        parts = source_id.split("::", 3)
        return nil if parts.size < 3

        parts[0]
      end

      def source_name : String
        source_id.split("::").last
      end
    end

    record ConversionRule,
      from_language : String,
      to_language : String,
      upstream_kind : String,
      crystal_kind : String,
      notes : String

    record SymbolItem,
      id : String,
      name : String,
      kind : String,
      file : String,
      scope : String,
      parser_mode : String

    record Match,
      symbol : SymbolItem,
      score : Int32,
      basis : String

    record ReportRow,
      source_id : String,
      kind : String,
      inventory_status : String,
      match_status : String,
      confidence : Int32,
      crystal_name : String,
      crystal_kind : String,
      crystal_path : String,
      basis : String,
      structural_status : String,
      structural_details : String,
      notes : String

    record AnalysisResult,
      rows : Array(ReportRow),
      parser_mode : String

    record StructuralFacts,
      graph : Graph::CodeGraph,
      entry_points : Array(String),
      scoped_calls : Array(Graph::IR::ScopedCallEdge) = [] of Graph::IR::ScopedCallEdge,
      entry_point_files : Array(Tuple(String, String)) = [] of Tuple(String, String)

    record StructuralSymbol,
      name : String,
      qualified_name : String? = nil

    record StructuralReport,
      source_symbol : String,
      target_symbol : String,
      status : String,
      source_defined : Bool,
      target_defined : Bool,
      source_exported : Bool,
      target_exported : Bool,
      source_entry_point : Bool,
      target_entry_point : Bool,
      matched_imports : Array(String),
      missing_imports : Array(String),
      extra_imports : Array(String),
      matched_calls : Array(String),
      missing_calls : Array(String),
      extra_calls : Array(String),
      matched_contains : Array(String),
      missing_contains : Array(String),
      extra_contains : Array(String)

    class Loader
      def self.read_inventory(path : String) : Array(InventoryRow)
        rows(path, 5).map do |cols|
          target_symbol = cols.size >= 6 ? cols[4].strip : ""
          test_refs = cols.size >= 7 ? cols[5].strip : ""
          notes = cols.size >= 8 ? cols[6].strip : cols[4].strip
          InventoryRow.new(
            source_id: cols[0],
            kind: cols[1],
            status: cols[2],
            crystal_refs: empty_to_dash(cols[3]),
            notes: empty_to_dash(notes),
            target_symbol: target_symbol,
            test_refs: test_refs,
          )
        end
      end

      def self.read_rules(path : String?) : Array(ConversionRule)
        return [] of ConversionRule unless path && File.file?(path)

        rows(path, 5).map do |cols|
          ConversionRule.new(
            from_language: cols[0],
            to_language: cols[1],
            upstream_kind: cols[2],
            crystal_kind: empty_to_dash(cols[3]),
            notes: empty_to_dash(cols[4]),
          )
        end
      end

      def self.read_report(path : String) : AnalysisResult
        parser_mode = "unknown"
        rows = [] of ReportRow

        File.each_line(path) do |line|
          stripped = line.strip
          next if stripped.empty?

          if stripped.starts_with?("# parser_mode=")
            parser_mode = stripped.lchop("# parser_mode=")
            next
          end

          next if stripped.starts_with?('#')

          cols = line.rstrip("\n").split('\t', remove_empty: false)
          raise "Malformed parity report row in #{path}: #{line}" if cols.size < 12

          rows << ReportRow.new(
            source_id: cols[0],
            kind: cols[1],
            inventory_status: cols[2],
            match_status: cols[3],
            confidence: cols[4].to_i,
            crystal_name: cols[5],
            crystal_kind: cols[6],
            crystal_path: cols[7],
            basis: cols[8],
            structural_status: cols[9],
            structural_details: cols[10],
            notes: cols[11],
          )
        end

        AnalysisResult.new(rows: rows, parser_mode: parser_mode)
      end

      private def self.rows(path : String, min_cols : Int32) : Array(Array(String))
        data = [] of Array(String)
        File.each_line(path) do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.starts_with?('#')

          cols = line.rstrip("\n").split('\t', remove_empty: false)
          raise "Malformed row in #{path}: #{line}" if cols.size < min_cols
          data << cols
        end
        data
      end

      private def self.empty_to_dash(value : String) : String
        stripped = value.strip
        stripped.empty? ? "-" : stripped
      end
    end

    module Naming
      extend self

      def normalized_key(name : String) : String
        segments(name).map { |segment| normalize_token(segment) }
          .reject(&.empty?)
          .join(".")
      end

      def normalized_simple(name : String) : String
        pieces = segments(name)
        return "" if pieces.empty?
        normalize_token(pieces.last)
      end

      def normalized_owner(name : String) : String
        pieces = segments(name)
        return "" if pieces.size < 2
        pieces[0...-1].map { |segment| normalize_token(segment) }
          .reject(&.empty?)
          .join(".")
      end

      def normalize_token(token : String) : String
        cleaned = token.gsub(/^@+/, "")
        cleaned = cleaned.gsub("+", "_plus_")
        cleaned = cleaned.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        cleaned = cleaned.gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        cleaned = cleaned.gsub(/[^A-Za-z0-9]+/, "_")
        cleaned = cleaned.downcase
        cleaned = cleaned.gsub(/(?:_escaped|escaped)\z/, "")
        cleaned.gsub(/^_+|_+$/, "").gsub(/_+/, "_")
      end

      private def segments(name : String) : Array(String)
        return [name] if name.includes?(' ')
        return name.split(/::|\./) if name.includes?("::") || name.includes?('.')
        [name]
      end
    end

    module Structural
      extend self

      def compare(
        source_graph : Graph::CodeGraph,
        source_symbol : String,
        target_graph : Graph::CodeGraph,
        target_symbol : String,
        source_entry_points : Array(String)? = nil,
        target_entry_points : Array(String)? = nil,
        source_file : String? = nil,
        target_file : String? = nil,
      ) : StructuralReport
        resolved_source_symbol = resolved_structural_symbol(source_graph, source_symbol, source_file)
        resolved_target_symbol = resolved_structural_symbol(target_graph, target_symbol, target_file)
        source_defined = defined?(source_graph, resolved_source_symbol, source_file)
        target_defined = defined?(target_graph, resolved_target_symbol, target_file)
        source_exported = exported?(source_graph, resolved_source_symbol, source_file)
        target_exported = exported?(target_graph, resolved_target_symbol, target_file)
        source_entry_point = entry_point?(entry_point_lookup_name(resolved_source_symbol), source_entry_points, source_file: source_file)
        target_entry_point = entry_point?(entry_point_lookup_name(resolved_target_symbol), target_entry_points, target_file: target_file)
        source_imports = normalized_imports(source_graph, resolved_source_symbol, source_file)
        target_imports = normalized_imports(target_graph, resolved_target_symbol, target_file)
        source_callees = normalized_callees(source_graph, resolved_source_symbol, source_file)
        target_callees = normalized_callees(target_graph, resolved_target_symbol, target_file)
        source_contains = normalized_contains(source_graph, resolved_source_symbol, source_file)
        target_contains = normalized_contains(target_graph, resolved_target_symbol, target_file)

        build_structural_report(
          source_symbol: source_symbol,
          target_symbol: target_symbol,
          source_defined: source_defined,
          target_defined: target_defined,
          source_exported: source_exported,
          target_exported: target_exported,
          source_entry_point: source_entry_point,
          target_entry_point: target_entry_point,
          source_imports: source_imports,
          target_imports: target_imports,
          source_callees: source_callees,
          target_callees: target_callees,
          source_contains: source_contains,
          target_contains: target_contains,
        )
      end

      def compare(
        source_facts : StructuralFacts,
        source_symbol : String,
        target_facts : StructuralFacts,
        target_symbol : String,
        source_file : String? = nil,
        target_file : String? = nil,
      ) : StructuralReport
        resolved_source_symbol = resolved_structural_symbol(source_facts.graph, source_symbol, source_file)
        resolved_target_symbol = resolved_structural_symbol(target_facts.graph, target_symbol, target_file)
        source_defined = defined?(source_facts.graph, resolved_source_symbol, source_file)
        target_defined = defined?(target_facts.graph, resolved_target_symbol, target_file)
        source_exported = exported?(source_facts.graph, resolved_source_symbol, source_file)
        target_exported = exported?(target_facts.graph, resolved_target_symbol, target_file)
        source_entry_point = entry_point?(entry_point_lookup_name(resolved_source_symbol), source_facts.entry_points, source_file: source_file, entry_point_files: source_facts.entry_point_files)
        target_entry_point = entry_point?(entry_point_lookup_name(resolved_target_symbol), target_facts.entry_points, target_file: target_file, entry_point_files: target_facts.entry_point_files)
        source_imports = normalized_imports(source_facts.graph, resolved_source_symbol, source_file)
        target_imports = normalized_imports(target_facts.graph, resolved_target_symbol, target_file)
        source_callees = normalized_callees(source_facts, resolved_source_symbol, source_file)
        target_callees = normalized_callees(target_facts, resolved_target_symbol, target_file)
        source_contains = normalized_contains(source_facts.graph, resolved_source_symbol, source_file)
        target_contains = normalized_contains(target_facts.graph, resolved_target_symbol, target_file)

        build_structural_report(
          source_symbol: source_symbol,
          target_symbol: target_symbol,
          source_defined: source_defined,
          target_defined: target_defined,
          source_exported: source_exported,
          target_exported: target_exported,
          source_entry_point: source_entry_point,
          target_entry_point: target_entry_point,
          source_imports: source_imports,
          target_imports: target_imports,
          source_callees: source_callees,
          target_callees: target_callees,
          source_contains: source_contains,
          target_contains: target_contains,
        )
      end

      private def build_structural_report(
        source_symbol : String,
        target_symbol : String,
        source_defined : Bool,
        target_defined : Bool,
        source_exported : Bool,
        target_exported : Bool,
        source_entry_point : Bool,
        target_entry_point : Bool,
        source_imports : Array(String),
        target_imports : Array(String),
        source_callees : Array(String),
        target_callees : Array(String),
        source_contains : Array(String),
        target_contains : Array(String),
      ) : StructuralReport
        matched_imports = source_imports & target_imports
        missing_imports = source_imports - target_imports
        extra_imports = target_imports - source_imports
        matched_calls = source_callees & target_callees
        missing_calls = source_callees - target_callees
        extra_calls = target_callees - source_callees
        matched_contains = source_contains & target_contains
        missing_contains = source_contains - target_contains
        extra_contains = target_contains - source_contains
        status = (
          source_defined &&
          target_defined &&
          source_exported == target_exported &&
          source_entry_point == target_entry_point &&
          missing_imports.empty? &&
          extra_imports.empty? &&
          missing_contains.empty? &&
          extra_contains.empty?
        ) ? "structural_match" : "structural_drift"

        StructuralReport.new(
          source_symbol: source_symbol,
          target_symbol: target_symbol,
          status: status,
          source_defined: source_defined,
          target_defined: target_defined,
          source_exported: source_exported,
          target_exported: target_exported,
          source_entry_point: source_entry_point,
          target_entry_point: target_entry_point,
          matched_imports: matched_imports.sort,
          missing_imports: missing_imports.sort,
          extra_imports: extra_imports.sort,
          matched_calls: matched_calls.sort,
          missing_calls: missing_calls.sort,
          extra_calls: extra_calls.sort,
          matched_contains: matched_contains.sort,
          missing_contains: missing_contains.sort,
          extra_contains: extra_contains.sort,
        )
      end

      def load_facts(path : String) : StructuralFacts
        graph = Graph::FactsSnapshot.load_graph_from_facts(path)
        defines = graph ? nil : ([] of Graph::DefinesFact)
        calls = graph ? nil : ([] of Graph::CallsFact)
        scoped_calls = [] of Graph::IR::ScopedCallEdge
        imports = graph ? nil : ([] of Graph::ImportsFact)
        exports = graph ? nil : ([] of Graph::ExportsFact)
        contains = graph ? nil : ([] of Graph::ContainsFact)
        qualified_names = [] of Tuple(String, String, String)
        signatures = [] of Tuple(String, String, String)
        entry_points = [] of String
        entry_point_files = [] of Tuple(String, String)

        File.each_line(path) do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.starts_with?('%') || stripped.starts_with?(":-")
          if stripped.starts_with?("defines(")
            next unless defines
            args = parse_args(stripped["defines(".size...-2])
            defines << Graph::DefinesFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
              kind: parse_symbol_kind(atom(args[2])),
              span: Graph::Span.line_range(args[3].to_i, args[4].to_i)
            )
          elsif stripped.starts_with?("qualified_name(")
            args = parse_args(stripped["qualified_name(".size...-2])
            qualified_names << {atom(args[0]), atom(args[1]), atom(args[2])}
          elsif stripped.starts_with?("signature(")
            args = parse_args(stripped["signature(".size...-2])
            signatures << {atom(args[0]), atom(args[1]), atom(args[2])}
          elsif stripped.starts_with?("calls_in(")
            args = parse_args(stripped["calls_in(".size...-2])
            scoped_calls << Graph::IR::ScopedCallEdge.new(
              file: atom(args[0]),
              caller: atom(args[1]),
              callee: atom(args[2]),
            )
          elsif stripped.starts_with?("calls(")
            next unless calls
            args = parse_args(stripped["calls(".size...-2])
            calls << Graph::CallsFact.new(
              caller: atom(args[0]),
              callee: atom(args[1]),
            )
          elsif stripped.starts_with?("imports(")
            next unless imports
            args = parse_args(stripped["imports(".size...-2])
            imports << Graph::ImportsFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
              source: atom(args[2]),
            )
          elsif stripped.starts_with?("exports(")
            next unless exports
            args = parse_args(stripped["exports(".size...-2])
            exports << Graph::ExportsFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
            )
          elsif stripped.starts_with?("contains(")
            next unless contains
            args = parse_args(stripped["contains(".size...-2])
            contains << Graph::ContainsFact.new(
              parent: atom(args[0]),
              child: atom(args[1]),
            )
          elsif stripped.starts_with?("entry_point_file(")
            args = parse_args(stripped["entry_point_file(".size...-2])
            entry_point_files << {atom(args[0]), atom(args[1])}
          elsif stripped.starts_with?("entry_point(")
            args = parse_args(stripped["entry_point(".size...-2])
            entry_points << atom(args[0])
          end
        end

        graph ||= Graph::CodeGraph.new(
          defines: defines || ([] of Graph::DefinesFact),
          calls: calls || ([] of Graph::CallsFact),
          imports: imports || ([] of Graph::ImportsFact),
          exports: exports || ([] of Graph::ExportsFact),
          contains: contains || ([] of Graph::ContainsFact),
        )
        attach_qualified_names!(graph, qualified_names) unless qualified_names.empty?
        attach_signatures!(graph, signatures) unless signatures.empty?

        StructuralFacts.new(
          graph: graph,
          entry_points: normalized_entry_points(entry_points),
          scoped_calls: scoped_calls,
          entry_point_files: entry_point_files,
        )
      end

      def load_graph(path : String) : Graph::CodeGraph
        load_facts(path).graph
      end

      private def defined?(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String? = nil) : Bool
        graph.defines.any? { |fact| define_matches?(fact, symbol) && (file.nil? || fact.file == file) }
      end

      private def exported?(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String? = nil) : Bool
        normalized_symbol = normalized_symbol_candidates(symbol)
        graph.exports.any? do |fact|
          normalized_symbol.includes?(Naming.normalized_simple(fact.name)) &&
            (file.nil? || fact.file == file)
        end
      end

      private def entry_point?(
        symbol : String,
        entry_points : Array(String)?,
        source_file : String? = nil,
        target_file : String? = nil,
        entry_point_files : Array(Tuple(String, String)) = [] of Tuple(String, String),
      ) : Bool
        file = source_file || target_file
        if file && !entry_point_files.empty?
          normalized_symbol = Naming.normalized_simple(symbol)
          return entry_point_files.any? do |entry_file, entry_name|
            entry_file == file && Naming.normalized_simple(entry_name) == normalized_symbol
          end
        end

        return false unless entry_points

        normalized_symbol = Naming.normalized_simple(symbol)
        entry_points.any? { |name| Naming.normalized_simple(name) == normalized_symbol }
      end

      private def normalized_imports(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String? = nil) : Array(String)
        file = file || defining_file(graph, symbol)
        return [] of String unless file

        imports = graph.imports.select { |fact| fact.file == file }
          .map { |fact| normalized_import_target(fact) }
          .reject(&.empty?)
        imports.uniq!
        imports.sort!
        imports
      end

      private def defining_file(graph : Graph::CodeGraph, symbol : StructuralSymbol) : String?
        graph.defines.find { |fact| define_matches?(fact, symbol) }.try(&.file)
      end

      private def normalized_import_target(fact : Graph::ImportsFact) : String
        source = fact.source.strip
        candidate = if source.empty?
                      fact.name
                    else
                      import_basename(source)
                    end
        Naming.normalized_simple(candidate)
      end

      private def import_basename(source : String) : String
        leaf = source.gsub('\\', '/').split('/').last? || source
        leaf = leaf.sub(/\.[A-Za-z0-9]+\z/, "")
        leaf
      end

      private def normalized_callees(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String? = nil) : Array(String)
        if file && ambiguous_definition?(graph, symbol, file)
          return [] of String
        end

        callees = graph.calls.select { |fact| call_matches?(fact, symbol) }
          .map { |fact| Naming.normalized_simple(fact.callee) }
          .reject(&.empty?)
        callees.uniq!
        callees.sort!
        callees
      end

      private def ambiguous_definition?(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String) : Bool
        matching_defines = graph.defines.select { |fact| define_matches?(fact, symbol) }
        return false if matching_defines.empty?
        return false if matching_defines.size == 1

        matching_defines.any? { |fact| fact.file == file }
      end

      private def normalized_callees(facts : StructuralFacts, symbol : StructuralSymbol, file : String? = nil) : Array(String)
        return normalized_callees(facts.graph, symbol, file) if file.nil? || facts.scoped_calls.empty?

        callees = facts.scoped_calls.select { |edge| edge.file == file && structural_symbol_matches?(edge.caller, symbol) }
          .map { |edge| Naming.normalized_simple(edge.callee) }
          .reject(&.empty?)
        callees.uniq!
        callees.sort!
        callees
      end

      private def normalized_contains(graph : Graph::CodeGraph, symbol : StructuralSymbol, file : String? = nil) : Array(String)
        contained = graph.contains.select do |fact|
          next false unless structural_symbol_matches?(fact.parent, symbol)
          next true if file.nil?

          graph.defines.any? do |define|
            define.file == file && (define.name == fact.child || define.qualified_name == fact.child)
          end
        end
          .map { |fact| Naming.normalized_simple(fact.child) }
          .reject(&.empty?)
        contained.uniq!
        contained.sort!
        contained
      end

      private def normalized_entry_points(entry_points : Array(String)) : Array(String)
        normalized = entry_points.dup
        normalized.uniq!
        normalized.sort!
        normalized
      end

      private def atom(value : String) : String
        stripped = value.strip
        if stripped.starts_with?('\'') && stripped.ends_with?('\'')
          stripped[1...-1].gsub("''", "'")
        else
          stripped
        end
      end

      private def parse_symbol_kind(value : String) : Graph::SymbolKind
        case value
        when "module"    then Graph::SymbolKind::Module
        when "class"     then Graph::SymbolKind::Class
        when "function"  then Graph::SymbolKind::Function
        when "method"    then Graph::SymbolKind::Method
        when "interface" then Graph::SymbolKind::Interface
        when "variable"  then Graph::SymbolKind::Variable
        when "type"      then Graph::SymbolKind::Type
        else
          Graph::SymbolKind::Variable
        end
      end

      private def parse_args(body : String) : Array(String)
        args = [] of String
        current = String::Builder.new
        in_quote = false
        i = 0

        while i < body.bytesize
          ch = body.byte_at(i).unsafe_chr
          if ch == '\''
            if in_quote && i + 1 < body.bytesize && body.byte_at(i + 1).unsafe_chr == '\''
              current << '\''
              i += 1
            else
              in_quote = !in_quote
              current << ch
            end
          elsif ch == ',' && !in_quote
            args << current.to_s.strip
            current = String::Builder.new
          else
            current << ch
          end
          i += 1
        end

        final = current.to_s.strip
        args << final unless final.empty?
        args
      end

      private def resolved_structural_symbol(graph : Graph::CodeGraph, symbol : String, file : String?) : StructuralSymbol
        normalized_symbol = normalize_structural_lookup(symbol)
        candidates = graph.defines.select { |fact| file.nil? || fact.file == file }

        if exact = candidates.find { |fact| fact.name == normalized_symbol || fact.qualified_name == normalized_symbol }
          return StructuralSymbol.new(name: exact.name, qualified_name: exact.qualified_name)
        end

        normalized_key = Naming.normalized_key(normalized_symbol)
        normalized_simple = Naming.normalized_simple(normalized_symbol)
        normalized_owner = Naming.normalized_owner(normalized_symbol)

        if qualified = candidates.find { |fact| qualified_name = fact.qualified_name; qualified_name && Naming.normalized_key(qualified_name) == normalized_key }
          return StructuralSymbol.new(name: qualified.name, qualified_name: qualified.qualified_name)
        end

        if !normalized_owner.empty?
          if owner_match = candidates.find { |fact| qualified_name = fact.qualified_name; qualified_name && Naming.normalized_simple(qualified_name) == normalized_simple && Naming.normalized_owner(qualified_name) == normalized_owner }
            return StructuralSymbol.new(name: owner_match.name, qualified_name: owner_match.qualified_name)
          end
        end

        if simple = candidates.find { |fact| Naming.normalized_simple(fact.name) == normalized_simple }
          return StructuralSymbol.new(name: simple.name, qualified_name: simple.qualified_name)
        end

        StructuralSymbol.new(name: normalized_symbol)
      end

      private def attach_qualified_names!(graph : Graph::CodeGraph, qualified_names : Array(Tuple(String, String, String))) : Nil
        # A file can define the same simple name more than once (nested enums,
        # overloads), so `{file, name}` alone is ambiguous. Facts are emitted in
        # `graph.defines` order, so consume the queued qualified names in order
        # per `{file, name}`.
        queues = Hash({String, String}, Array(String)).new { |hash, key| hash[key] = [] of String }
        qualified_names.each { |file, name, qualified_name| queues[{file, name}] << qualified_name }

        offsets = Hash({String, String}, Int32).new(0)
        graph.defines.map! do |fact|
          key = {fact.file, fact.name}
          queue = queues[key]?
          unless queue
            next fact
          end

          offset = offsets[key]
          next fact if offset >= queue.size

          offsets[key] = offset + 1
          fact.copy_with(qualified_name: queue[offset])
        end
      end

      private def attach_signatures!(graph : Graph::CodeGraph, signatures : Array(Tuple(String, String, String))) : Nil
        queues = Hash({String, String}, Array(String)).new { |hash, key| hash[key] = [] of String }
        signatures.each { |file, name, signature| queues[{file, name}] << signature }

        offsets = Hash({String, String}, Int32).new(0)
        graph.defines.map! do |fact|
          key = {fact.file, fact.name}
          queue = queues[key]?
          unless queue
            next fact
          end

          offset = offsets[key]
          next fact if offset >= queue.size

          offsets[key] = offset + 1
          fact.copy_with(signature: queue[offset])
        end
      end

      private def normalize_structural_lookup(symbol : String) : String
        symbol.gsub('#', '.').strip
      end

      private def normalized_symbol_candidates(symbol : StructuralSymbol) : Set(String)
        values = Set(String).new
        values << Naming.normalized_simple(symbol.name)
        if qualified_name = symbol.qualified_name
          values << Naming.normalized_simple(qualified_name)
        end
        values
      end

      private def entry_point_lookup_name(symbol : StructuralSymbol) : String
        symbol.qualified_name || symbol.name
      end

      private def define_matches?(fact : Graph::DefinesFact, symbol : StructuralSymbol) : Bool
        return true if fact.name == symbol.name

        qualified_name = symbol.qualified_name
        return false unless qualified_name

        fact.qualified_name == qualified_name
      end

      private def call_matches?(fact : Graph::CallsFact, symbol : StructuralSymbol) : Bool
        return true if structural_symbol_matches?(fact.caller, symbol)

        qualified_name = symbol.qualified_name
        return false unless qualified_name

        fact.caller_qn == qualified_name
      end

      private def structural_symbol_matches?(value : String, symbol : StructuralSymbol) : Bool
        return true if value == symbol.name

        qualified_name = symbol.qualified_name
        return false unless qualified_name

        value == qualified_name
      end
    end

    class CrystalScanner
      @@before_collect_file_read_hook = nil.as((String -> Nil)?)
      @@before_collect_file_read_hook_mutex = Mutex.new
      @@collect_file_max_concurrency_for_test = nil.as(Int32?)
      @@collect_file_max_concurrency_for_test_mutex = Mutex.new

      def self.scan(root_dir : String, dirs : Array(String), parser_mode : String? = nil) : Tuple(Array(SymbolItem), String)
        force = parser_mode.try(&.downcase)
        register_vendor_grammars(root_dir)

        if force == "tree-sitter"
          items = tree_sitter_scan(root_dir, dirs, "tree-sitter")
          return {deduplicate(items), "tree-sitter"}
        end

        if force != "regex" && Discovery.tree_sitter_available?("crystal")
          begin
            items = tree_sitter_scan(root_dir, dirs, nil)
            return {deduplicate(items), "tree-sitter"}
          rescue ex
            # Keep the report usable when discovery cannot parse the workspace.
          end
        end

        {regex_scan(root_dir, dirs), "regex"}
      end

      private def self.register_vendor_grammars(root_dir : String) : Nil
        # A target repository may provide an explicit grammar override.
        vendor_dir = File.join(root_dir, "vendor", "grammars")
        Discovery.register_grammar_directory(vendor_dir) if Dir.exists?(vendor_dir)

        # Isolated fixtures and external repositories must not need to carry
        # their own Crystal grammar. Fall back to Chiasmus's bundled bundle,
        # then GrammarLoader's process-wide XDG cache.
        bundled_dir = File.expand_path("../../grammars", __DIR__)
        Discovery.register_grammar_directory(bundled_dir) if Dir.exists?(bundled_dir)
      end

      private def self.tree_sitter_scan(root_dir : String, dirs : Array(String), force_parser : String?) : Array(SymbolItem)
        files = collect_files(root_dir, dirs)
        absolute_root = File.expand_path(root_dir)
        result = Discovery.discover_files("crystal", files, force_parser: force_parser)
        result.items.compact_map do |item|
          next unless allowed_kind?(item.kind)
          SymbolItem.new(
            id: item.id,
            name: item.name,
            kind: item.kind,
            file: relative_to_root(item.file, absolute_root),
            scope: item.scope,
            parser_mode: result.parser_mode,
          )
        end
      end

      private def self.regex_scan(root_dir : String, dirs : Array(String)) : Array(SymbolItem)
        absolute_root = File.expand_path(root_dir)
        files = crystal_file_paths(absolute_root, dirs)
        extracted = Parity.parallel_map(files) do |path|
          rel = relative_to_root(path, absolute_root)
          begin
            extract_regex(rel, File.read(path))
          rescue ex
            [] of SymbolItem
          end
        end

        deduplicate(extracted.flatten)
      end

      private def self.collect_files(root_dir : String, dirs : Array(String)) : Array(Tuple(String, String))
        absolute_root = File.expand_path(root_dir)
        paths = crystal_file_paths(absolute_root, dirs)

        source_files = Graph::FileIO.read_source_files_parallel(paths, collect_file_max_concurrency) do |path|
          run_before_collect_file_read_hook(path)
          File.read(path)
        end
        source_files.map do |source_file|
          {relative_to_root(source_file.path, absolute_root), source_file.content}
        end
      end

      private def self.relative_to_root(path : String, absolute_root : String) : String
        prefix = "#{absolute_root}/"
        path.starts_with?(prefix) ? path[prefix.size..] : path
      end

      private def self.extract_regex(rel : String, text : String) : Array(SymbolItem)
        items = [] of SymbolItem
        namespace = [] of String
        in_spec = rel.ends_with?("_spec.cr") || rel.starts_with?("spec/")

        text.each_line do |line|
          stripped = line.strip

          if match = stripped.match(/^(class|module|struct|enum|lib|annotation)\s+([A-Z][A-Za-z0-9_:]*)/)
            kind = match[1] == "module" ? "interface" : match[1]
            name = match[2]
            namespace << name
            items << symbol_item(rel, kind, name, "source", "regex")
            next
          end

          if stripped == "end"
            namespace.pop?
            next
          end

          if match = stripped.match(/^([A-Z][A-Z0-9_:]*)\s*=/)
            items << symbol_item(rel, "const", match[1], "source", "regex")
          end

          if match = stripped.match(/^def\s+(?:self\.)?([a-z_][A-Za-z0-9_!?=]*)/)
            method_name = match[1]
            owner = namespace.join("::")
            full_name = owner.empty? ? method_name : "#{owner}.#{method_name}"
            items << symbol_item(rel, "method", full_name, "source", "regex")
          end

          next unless in_spec

          if match = stripped.match(/^describe\s+["'](.+?)["']/)
            items << symbol_item(rel, "test", match[1], "test", "regex")
          end

          if match = stripped.match(/^it\s+["'](.+?)["']/)
            items << symbol_item(rel, "test", match[1], "test", "regex")
          end
        end

        deduplicate(items)
      end

      private def self.symbol_item(file : String, kind : String, name : String, scope : String, parser_mode : String) : SymbolItem
        SymbolItem.new(
          id: "#{file}::#{kind}::#{name}",
          name: name,
          kind: kind,
          file: file,
          scope: scope,
          parser_mode: parser_mode,
        )
      end

      private def self.allowed_kind?(kind : String) : Bool
        VALID_CANDIDATE_KINDS.includes?(kind)
      end

      protected def self.run_before_collect_file_read_hook(path : String) : Nil
        hook = @@before_collect_file_read_hook_mutex.synchronize { @@before_collect_file_read_hook }
        hook.try(&.call(path))
      end

      private def self.collect_file_max_concurrency : Int32
        override = @@collect_file_max_concurrency_for_test_mutex.synchronize { @@collect_file_max_concurrency_for_test }
        Math.max(1, override || MAX_CONCURRENCY)
      end

      def self.set_before_collect_file_read_hook_for_test(&block : String ->) : Nil
        @@before_collect_file_read_hook_mutex.synchronize do
          @@before_collect_file_read_hook = block
        end
      end

      def self.clear_before_collect_file_read_hook_for_test : Nil
        @@before_collect_file_read_hook_mutex.synchronize do
          @@before_collect_file_read_hook = nil
        end
      end

      def self.collect_file_max_concurrency_for_test=(value : Int32) : Nil
        @@collect_file_max_concurrency_for_test_mutex.synchronize do
          @@collect_file_max_concurrency_for_test = value
        end
      end

      def self.clear_collect_file_max_concurrency_for_test : Nil
        @@collect_file_max_concurrency_for_test_mutex.synchronize do
          @@collect_file_max_concurrency_for_test = nil
        end
      end

      private def self.deduplicate(items : Array(SymbolItem)) : Array(SymbolItem)
        seen = Set(String).new
        items.select { |item| seen.add?(item.id) }
      end

      private def self.crystal_file_paths(absolute_root : String, dirs : Array(String)) : Array(String)
        files = [] of String
        dirs.each do |dir|
          abs_dir = File.expand_path(dir, absolute_root)
          next unless Dir.exists?(abs_dir)

          Index::DirectoryWalk.files(abs_dir, max_depth: 50).each do |path|
            next unless path.ends_with?(".cr")
            next if appledouble_path?(path)
            files << path
          end
        end
        files
      end

      private def self.appledouble_path?(path : String) : Bool
        path.split('/').any?(&.starts_with?("._"))
      end
    end

    class Matcher
      @equivalences : Array(Utils::Config::RepoParityConfig::RepoParityEquivalence)

      def initialize(
        @symbols : Array(SymbolItem),
        @rules : Array(ConversionRule),
        @source_graph : Graph::CodeGraph? = nil,
        @crystal_graph : Graph::CodeGraph? = nil,
        @source_entry_points : Array(String)? = nil,
        @crystal_entry_points : Array(String)? = nil,
        @source_facts : StructuralFacts? = nil,
        @crystal_facts : StructuralFacts? = nil,
        @parity_config : Utils::Config::RepoParityConfig? = nil,
      )
        @symbols_by_file = Hash(String, Array(SymbolItem)).new { |hash, key| hash[key] = [] of SymbolItem }
        @rules_by_upstream = Hash(String, Array(ConversionRule)).new { |hash, key| hash[key] = [] of ConversionRule }
        @equivalences = usable_equivalences(@parity_config)

        @symbols.each do |symbol|
          index_paths_for(symbol.file).each do |path|
            @symbols_by_file[path] << symbol
          end
        end

        @rules.each do |rule|
          @rules_by_upstream[Naming.normalized_simple(rule.upstream_kind)] << rule
        end
      end

      def analyze(rows : Array(InventoryRow)) : Array(ReportRow)
        Parity.parallel_map(rows) { |row| analyze_row(row) }
      end

      private def analyze_row(row : InventoryRow) : ReportRow
        ref_paths = crystal_ref_paths(row.crystal_refs)
        referenced = symbols_for_paths(ref_paths)
        missing_refs = missing_ref_paths(ref_paths)

        if row.status == "intentional_divergence"
          return intentional_divergence_report(row, referenced, missing_refs)
        end

        if match = best_match(row, referenced)
          status = match.basis == "exact" ? "curated_exact" : "curated_alias"
          return build_report(row, status, match, row.notes)
        end

        unless referenced.empty?
          return report_from_symbol(row, "curated_ref_only", referenced.first, row.notes, 50, "ref_path")
        end

        unless missing_refs.empty?
          global_match = best_match(row, @symbols)
          return stale_ref_report(row, missing_refs, global_match)
        end

        matches = ranked_matches(row, @symbols)
        if matches.empty?
          return ReportRow.new(
            source_id: row.source_id,
            kind: row.kind,
            inventory_status: row.status,
            match_status: "unmapped",
            confidence: 0,
            crystal_name: "-",
            crystal_kind: "-",
            crystal_path: "-",
            basis: "none",
            structural_status: "-",
            structural_details: "-",
            notes: row.notes,
          )
        end

        best = matches.first
        if matches.size > 1 && matches[1].score == best.score
          return build_report(row, "ambiguous_candidate", best, row.notes)
        end

        status = best.score >= 96 ? "candidate_exact" : "candidate_alias"
        build_report(row, status, best, row.notes)
      end

      private def intentional_divergence_report(row : InventoryRow, referenced : Array(SymbolItem), missing_refs : Array(String)) : ReportRow
        if rule = matching_rule(row)
          return report_from_rule(row, rule)
        end

        if match = best_match(row, referenced)
          return build_report(row, "intentional_divergence", match, row.notes)
        end

        return report_from_symbol(row, "intentional_divergence", referenced.first, row.notes) unless referenced.empty?
        return stale_ref_report(row, missing_refs) unless missing_refs.empty?

        empty_report(row, "intentional_divergence", 100, "inventory_status", row.notes)
      end

      private def build_report(row : InventoryRow, status : String, match : Match, notes : String) : ReportRow
        structural_status, structural_details = structural_fields(row, match.symbol, row.status)
        ReportRow.new(
          source_id: row.source_id,
          kind: row.kind,
          inventory_status: row.status,
          match_status: status,
          confidence: match.score,
          crystal_name: match.symbol.name,
          crystal_kind: match.symbol.kind,
          crystal_path: match.symbol.file,
          basis: match.basis,
          structural_status: structural_status,
          structural_details: structural_details,
          notes: notes,
        )
      end

      private def report_from_symbol(row : InventoryRow, status : String, symbol : SymbolItem, notes : String, confidence : Int32 = 100, basis : String = "ref_path") : ReportRow
        structural_status, structural_details = structural_fields(row, symbol, row.status)
        ReportRow.new(
          source_id: row.source_id,
          kind: row.kind,
          inventory_status: row.status,
          match_status: status,
          confidence: confidence,
          crystal_name: symbol.name,
          crystal_kind: symbol.kind,
          crystal_path: symbol.file,
          basis: basis,
          structural_status: structural_status,
          structural_details: structural_details,
          notes: notes,
        )
      end

      private def empty_report(row : InventoryRow, status : String, confidence : Int32, basis : String, notes : String) : ReportRow
        ReportRow.new(
          source_id: row.source_id,
          kind: row.kind,
          inventory_status: row.status,
          match_status: status,
          confidence: confidence,
          crystal_name: "-",
          crystal_kind: "-",
          crystal_path: "-",
          basis: basis,
          structural_status: "-",
          structural_details: "-",
          notes: notes,
        )
      end

      private def report_from_rule(row : InventoryRow, rule : ConversionRule) : ReportRow
        crystal_name = rule.crystal_kind == "-" ? "-" : rule.crystal_kind
        ReportRow.new(
          source_id: row.source_id,
          kind: row.kind,
          inventory_status: row.status,
          match_status: "intentional_divergence",
          confidence: 100,
          crystal_name: crystal_name,
          crystal_kind: "-",
          crystal_path: "-",
          basis: "conversion_rule",
          structural_status: "-",
          structural_details: "-",
          notes: row.notes == "-" ? rule.notes : row.notes,
        )
      end

      private def matching_rule(row : InventoryRow) : ConversionRule?
        @rules_by_upstream[Naming.normalized_simple(row.source_name)].first?
      end

      private def crystal_ref_paths(refs : String) : Array(String)
        return [] of String if refs == "-"

        paths = refs.split(/[\s,]+/).compact_map do |token|
          stripped = token.strip
          next if stripped.empty? || stripped == "-"
          path = stripped.split(":").first
          next unless path.ends_with?(".cr")
          path
        end
        paths.uniq!
        paths
      end

      private def symbols_for_paths(paths : Array(String)) : Array(SymbolItem)
        symbols = paths.flat_map { |path| @symbols_by_file[path]? || [] of SymbolItem }
        symbols.uniq!
        symbols
      end

      private def missing_ref_paths(paths : Array(String)) : Array(String)
        paths.reject { |path| @symbols_by_file.has_key?(path) }
      end

      private def stale_ref_report(row : InventoryRow, missing_refs : Array(String), match : Match? = nil) : ReportRow
        notes = append_notes(row.notes, "stale crystal_refs: #{missing_refs.join(", ")}")

        if match
          structural_status, structural_details = structural_fields(row, match.symbol, row.status)
          return ReportRow.new(
            source_id: row.source_id,
            kind: row.kind,
            inventory_status: row.status,
            match_status: "stale_ref_path",
            confidence: match.score,
            crystal_name: match.symbol.name,
            crystal_kind: match.symbol.kind,
            crystal_path: match.symbol.file,
            basis: "stale_ref_path",
            structural_status: structural_status,
            structural_details: structural_details,
            notes: notes,
          )
        end

        empty_report(row, "stale_ref_path", 0, "stale_ref_path", notes)
      end

      private def append_notes(existing : String, extra : String) : String
        return extra if existing == "-"
        return existing if existing.includes?(extra)

        "#{existing}; #{extra}"
      end

      private def structural_fields(row : InventoryRow, symbol : SymbolItem, inventory_status : String) : Tuple(String, String)
        return {"-", "-"} if inventory_status == "intentional_divergence"
        source_file = resolved_source_graph_file(row.source_file)
        target_file = resolved_target_graph_file(symbol.file)
        report = if source_facts = @source_facts
                   if crystal_facts = @crystal_facts
                     Structural.compare(
                       source_facts,
                       row.source_name,
                       crystal_facts,
                       symbol.name,
                       source_file: source_file,
                       target_file: target_file,
                     )
                   else
                     return {"-", "-"}
                   end
                 else
                   source_graph = @source_graph
                   crystal_graph = @crystal_graph
                   return {"-", "-"} unless source_graph && crystal_graph

                   Structural.compare(
                     source_graph,
                     row.source_name,
                     crystal_graph,
                     symbol.name,
                     source_entry_points: @source_entry_points,
                     target_entry_points: @crystal_entry_points,
                     source_file: source_file,
                     target_file: target_file,
                   )
                 end
        details = structural_detail_lines(report)
        {report.status, details.empty? ? "-" : details.join("; ")}
      end

      private def structural_detail_lines(report : StructuralReport) : Array(String)
        details = [] of String
        append_presence_details(details, report)
        append_relation_details(details, "imports", report.matched_imports, report.missing_imports, report.extra_imports)
        append_relation_details(details, "contains", report.matched_contains, report.missing_contains, report.extra_contains)
        details
      end

      private def append_presence_details(details : Array(String), report : StructuralReport) : Nil
        details << "source_defined=false" unless report.source_defined
        details << "target_defined=false" unless report.target_defined
        if report.source_exported != report.target_exported
          details << "source_exported=#{report.source_exported}"
          details << "target_exported=#{report.target_exported}"
        end
        if report.source_entry_point != report.target_entry_point
          details << "source_entry_point=#{report.source_entry_point}"
          details << "target_entry_point=#{report.target_entry_point}"
        end
      end

      private def append_relation_details(
        details : Array(String),
        label : String,
        matched : Array(String),
        missing : Array(String),
        extra : Array(String),
      ) : Nil
        details << "matched_#{label}=#{matched.join(",")}" unless matched.empty?
        details << "missing_#{label}=#{missing.join(",")}" unless missing.empty?
        details << "extra_#{label}=#{extra.join(",")}" unless extra.empty?
      end

      private def best_match(row : InventoryRow, symbols : Array(SymbolItem)) : Match?
        ranked_matches(row, symbols).first?
      end

      private def ranked_matches(row : InventoryRow, symbols : Array(SymbolItem)) : Array(Match)
        matches = if explicit_target_symbol?(row)
                    symbols.compact_map do |symbol|
                      score_target_symbol(row, symbol)
                    end
                  else
                    symbols.compact_map do |symbol|
                      score_match(row, symbol)
                    end
                  end
        matches.sort_by! { |match| {-match.score, match.symbol.file, match.symbol.name} }
        matches
      end

      private def explicit_target_symbol?(row : InventoryRow) : Bool
        target = row.target_symbol.strip
        !target.empty? && target != "-"
      end

      private def score_target_symbol(row : InventoryRow, symbol : SymbolItem) : Match?
        equivalence = matching_equivalence(row.source_file, symbol.file)
        raw_target_symbol = normalized_target_symbol(row.target_symbol)
        target_symbol = normalized_target_symbol(normalized_target_name(row.target_symbol, equivalence))
        normalized_symbol_name = normalized_symbol_name(symbol.name, equivalence)
        target_key = Naming.normalized_key(target_symbol)
        target_simple = Naming.normalized_simple(target_symbol)
        target_owner = Naming.normalized_owner(target_symbol)
        symbol_key = Naming.normalized_key(normalized_symbol_name)
        symbol_simple = Naming.normalized_simple(normalized_symbol_name)
        symbol_owner = Naming.normalized_owner(normalized_symbol_name)

        return nil if target_simple.empty? || symbol_simple.empty?

        score, basis =
          if raw_target_symbol == symbol.name
            {100, "target_symbol"}
          elsif target_key == symbol_key
            {98, "target_symbol"}
          elsif target_simple == symbol_simple && !target_owner.empty? && target_owner == symbol_owner
            {94, "target_symbol"}
          elsif target_simple == symbol_simple
            {90, "target_symbol"}
          else
            {0, "target_symbol"}
          end

        return nil if score == 0

        score += compatible_kind?(row.kind, symbol.kind) ? 2 : -10
        score = 100 if score > 100
        return nil if score < 80

        Match.new(symbol: symbol, score: score, basis: basis)
      end

      private def normalized_target_symbol(value : String) : String
        value.gsub('#', '.').strip
      end

      private def score_match(row : InventoryRow, symbol : SymbolItem) : Match?
        equivalence = matching_equivalence(row.source_file, symbol.file)
        raw_source_name = row.source_name
        source_name = normalized_source_name(raw_source_name, equivalence)
        symbol_name = normalized_symbol_name(symbol.name, equivalence)
        source_key = Naming.normalized_key(source_name)
        source_simple = Naming.normalized_simple(source_name)
        source_owner = Naming.normalized_owner(source_name)
        symbol_key = Naming.normalized_key(symbol_name)
        symbol_simple = Naming.normalized_simple(symbol_name)
        symbol_owner = Naming.normalized_owner(symbol_name)

        return nil if source_simple.empty? || symbol_simple.empty?

        if match = constructor_owner_match(source_name, symbol, symbol_simple)
          return match
        end

        score, basis = name_score(row, symbol, raw_source_name, source_name, source_key, source_simple, source_owner, symbol_name, symbol_key, symbol_simple, symbol_owner)

        return nil if score == 0

        score += compatible_kind?(row.kind, symbol.kind) ? 2 : -10

        score = 100 if score > 100
        return nil if score < 80

        Match.new(symbol: symbol, score: score, basis: basis)
      end

      private def constructor_owner_match(source_name : String, symbol : SymbolItem, symbol_simple : String) : Match?
        return nil unless source_name.ends_with?(".constructor")

        owner = source_name.split(".")[0]
        return nil unless Naming.normalized_simple(owner) == symbol_simple
        return nil unless %w[class interface type].includes?(symbol.kind)

        Match.new(symbol: symbol, score: 93, basis: "constructor_owner")
      end

      private def name_score(
        row : InventoryRow,
        symbol : SymbolItem,
        raw_source_name : String,
        source_name : String,
        source_key : String,
        source_simple : String,
        source_owner : String,
        symbol_name : String,
        symbol_key : String,
        symbol_simple : String,
        symbol_owner : String,
      ) : Tuple(Int32, String)
        if row.kind == "test"
          return {100, "exact"} if source_key == symbol_key
          return {0, "simple_name"}
        end

        return {100, "exact"} if raw_source_name == symbol.name
        return {96, "normalized"} if source_key == symbol_key
        return {94, "qualified_suffix"} if source_simple == symbol_simple && !source_owner.empty? && source_owner == symbol_owner
        return {88, "simple_name"} if source_simple == symbol_simple

        {0, "simple_name"}
      end

      private def compatible_kind?(source_kind : String, crystal_kind : String) : Bool
        case source_kind
        when "function"
          %w[function method].includes?(crystal_kind)
        when "method"
          %w[method function].includes?(crystal_kind)
        when "interface"
          %w[interface class type enum].includes?(crystal_kind)
        when "class"
          %w[class interface type enum].includes?(crystal_kind)
        when "type"
          %w[type interface class enum].includes?(crystal_kind)
        when "const"
          crystal_kind == "const"
        when "test"
          crystal_kind == "test"
        else
          crystal_kind == source_kind
        end
      end

      private def usable_equivalences(config : Utils::Config::RepoParityConfig?) : Array(Utils::Config::RepoParityConfig::RepoParityEquivalence)
        return [] of Utils::Config::RepoParityConfig::RepoParityEquivalence unless config

        config.equivalences.try(&.select do |equivalence|
          source_path = normalized_path_prefix(equivalence.source_path)
          target_path = normalized_path_prefix(equivalence.target_path)
          !source_path.empty? && !target_path.empty?
        end) || [] of Utils::Config::RepoParityConfig::RepoParityEquivalence
      end

      private def resolved_source_graph_file(file : String?) : String?
        return nil unless file

        graph = @source_facts.try(&.graph) || @source_graph
        return file unless graph

        resolve_graph_file(graph, file, source_graph_file_candidates(file))
      end

      private def source_graph_file_candidates(file : String) : Array(String)
        candidates = [normalize_path(file)]
        vendor_src = normalized_path_prefix(@parity_config.try(&.vendor_src))
        candidates << normalize_path(File.join(vendor_src, file)) unless vendor_src.empty?
        candidates.uniq!
        candidates
      end

      private def resolved_target_graph_file(file : String?) : String?
        return nil unless file

        graph = @crystal_facts.try(&.graph) || @crystal_graph
        return file unless graph

        resolve_graph_file(graph, file, [normalize_path(file)])
      end

      private def resolve_graph_file(graph : Graph::CodeGraph, original_file : String, candidates : Array(String)) : String
        graph.defines.each do |fact|
          return fact.file if candidates.includes?(normalize_path(fact.file))
        end

        original_file
      end

      private def index_paths_for(path : String) : Array(String)
        keys = [normalize_path(path)]
        @equivalences.each do |equivalence|
          source_path = normalized_path_prefix(equivalence.source_path)
          target_path = normalized_path_prefix(equivalence.target_path)
          alias_path = rewrite_path_prefix(path, target_path, source_path)
          keys << alias_path unless alias_path.empty?
        end
        keys.uniq!
        keys
      end

      private def matching_equivalence(source_file : String?, target_file : String?) : Utils::Config::RepoParityConfig::RepoParityEquivalence?
        return nil unless source_file && target_file

        normalized_source = normalize_path(source_file)
        normalized_target = normalize_path(target_file)
        @equivalences.find do |equivalence|
          source_path = normalized_path_prefix(equivalence.source_path)
          target_path = normalized_path_prefix(equivalence.target_path)
          path_matches_prefix?(normalized_source, source_path) &&
            path_matches_prefix?(normalized_target, target_path)
        end
      end

      private def normalized_source_name(name : String, equivalence : Utils::Config::RepoParityConfig::RepoParityEquivalence?) : String
        strip_namespace_prefix(name, equivalence.try(&.source_namespace))
      end

      private def normalized_target_name(name : String, equivalence : Utils::Config::RepoParityConfig::RepoParityEquivalence?) : String
        strip_namespace_prefix(name, equivalence.try(&.target_namespace))
      end

      private def normalized_symbol_name(name : String, equivalence : Utils::Config::RepoParityConfig::RepoParityEquivalence?) : String
        normalized_target_name(name, equivalence)
      end

      private def strip_namespace_prefix(name : String, prefix : String?) : String
        return name if prefix.nil?

        normalized_prefix = prefix.strip
        return name if normalized_prefix.empty?

        variants = [normalized_prefix, normalized_prefix.gsub("::", ".")]
        variants.each do |candidate|
          if name == candidate
            return ""
          end

          ["::", "."].each do |separator|
            prefix_with_separator = "#{candidate}#{separator}"
            return name[prefix_with_separator.size..] if name.starts_with?(prefix_with_separator)
          end
        end

        name
      end

      private def normalize_path(path : String) : String
        path.gsub('\\', '/').gsub(%r{/+}, "/").sub(%r{^\./}, "").sub(%r{/$}, "")
      end

      private def normalized_path_prefix(path : String?) : String
        return "" unless path

        normalize_path(path)
      end

      private def path_matches_prefix?(path : String, prefix : String) : Bool
        return false if prefix.empty?

        path == prefix || path.starts_with?("#{prefix}/")
      end

      private def rewrite_path_prefix(path : String, from_prefix : String, to_prefix : String) : String
        return "" if from_prefix.empty? || to_prefix.empty?

        normalized_path = normalize_path(path)
        return "" unless path_matches_prefix?(normalized_path, from_prefix)

        suffix = normalized_path.size == from_prefix.size ? "" : normalized_path[(from_prefix.size + 1)..]
        suffix.empty? ? to_prefix : File.join(to_prefix, suffix).gsub('\\', '/')
      end
    end

    def self.analyze(
      inventory_path : String,
      root_dir : String = ".",
      crystal_dirs : Array(String) = [] of String,
      rules_path : String? = nil,
      parser_mode : String? = nil,
      source_facts_path : String? = nil,
      crystal_facts_path : String? = nil,
      repo_parity_config : Utils::Config::RepoParityConfig? = nil,
    ) : AnalysisResult
      parity_config = repo_parity_config || Utils::Config.load_repo_config(root_dir).parity
      effective_dirs = if crystal_dirs.empty?
                         parity_config.try(&.target_src) || ["src", "spec"]
                       else
                         crystal_dirs
                       end
      inventory = Loader.read_inventory(inventory_path)
      rules = Loader.read_rules(rules_path)
      symbols, parser = CrystalScanner.scan(root_dir, effective_dirs, parser_mode)
      source_facts = source_facts_path ? Structural.load_facts(source_facts_path) : nil
      crystal_facts = crystal_facts_path ? Structural.load_facts(crystal_facts_path) : nil
      matcher = Matcher.new(
        symbols,
        rules,
        source_graph: source_facts.try(&.graph),
        crystal_graph: crystal_facts.try(&.graph),
        source_entry_points: source_facts.try(&.entry_points),
        crystal_entry_points: crystal_facts.try(&.entry_points),
        source_facts: source_facts,
        crystal_facts: crystal_facts,
        parity_config: parity_config,
      )
      AnalysisResult.new(rows: matcher.analyze(inventory), parser_mode: parser)
    end

    # Joins a curated port inventory against `Reconcile` mappings to surface
    # ledger-vs-structure divergences mechanically:
    #   - `falsely_missing`: the ledger says `missing` but a Crystal counterpart
    #     reconciles structurally.
    #   - `falsely_ported`: the ledger says `ported` but no Crystal counterpart
    #     reconciles structurally.
    module InventoryJoin
      extend self

      record DivergenceRow,
        source_id : String,
        kind : String,
        inventory_status : String,
        map_status : String,
        divergence : String,
        target_name : String,
        entity_id : String? = nil,
        target_id : String? = nil,
        target_file : String? = nil,
        target_owner : String? = nil,
        basis : String = "-"

      def divergences(
        inventory : Array(InventoryRow),
        mappings : Array(Reconcile::Mapping),
        rules : Rules::RuleSet,
      ) : Array(DivergenceRow)
        normalizer = Rules::Normalizer.new(rules)
        by_name = Hash(String, Array(Reconcile::Mapping)).new { |hash, key| hash[key] = [] of Reconcile::Mapping }
        by_canonical = Hash(String, Array(Reconcile::Mapping)).new { |hash, key| hash[key] = [] of Reconcile::Mapping }
        mappings.each do |mapping|
          by_name[mapping.source_name] << mapping
          by_canonical[mapping.canonical] << mapping
        end

        inventory.map do |row|
          # Prefer the exact fact mapping (avoids conflating distinct source
          # entities that merely share a canonical key). Fall back to canonical
          # + owner when the extractor emitted a bare qualified name.
          candidates = by_name[row.source_name]? || [] of Reconcile::Mapping
          if candidates.empty?
            canonical = normalizer.canonical(Rules::Normalizer::Side::Source, row.source_name)
            owner = inventory_owner(normalizer, rules, row)
            candidates = (by_canonical[canonical]? || [] of Reconcile::Mapping).select do |mapping|
              owner.nil? || mapping.source_owner.nil? || mapping.source_owner == owner
            end
          end

          candidates = candidates.select { |mapping| kind_compatible?(row.kind, mapping.source_kind) }
          map_status = best_status(candidates)
          matched = candidates.find(&.status.==("matched"))
          linked = matched || candidates.first?
          DivergenceRow.new(
            source_id: row.source_id,
            kind: row.kind,
            inventory_status: row.status,
            map_status: map_status,
            divergence: divergence_for(row.status, map_status),
            target_name: matched.try(&.target_name) || "-",
            entity_id: linked.try(&.source_id),
            target_id: linked.try(&.target_id),
            target_file: linked.try { |mapping| mapping.target_id.try(&.split("::").first) },
            target_owner: linked.try(&.target_owner),
            basis: linked.try(&.basis) || "-",
          )
        end
      end

      def kind_compatible?(inventory_kind : String, fact_kind : String) : Bool
        return true if inventory_kind == fact_kind

        case inventory_kind
        when "const"     then ["variable", "const", "constant"].includes?(fact_kind)
        when "enum"      then ["class", "type", "interface", "module"].includes?(fact_kind)
        when "class"     then ["class", "module", "struct", "interface"].includes?(fact_kind)
        when "interface" then ["interface", "module", "class"].includes?(fact_kind)
        when "method"    then ["method", "function"].includes?(fact_kind)
        else                  false
        end
      end

      private def inventory_owner(normalizer : Rules::Normalizer, rules : Rules::RuleSet, row : InventoryRow) : String?
        file = row.source_file
        return nil unless file

        leaf = File.dirname(file).split('/').reject(&.empty?).last?
        return nil unless leaf

        normalizer.key(normalizer.normalize(rules.source, leaf))
      end

      private def best_status(candidates : Array(Reconcile::Mapping)) : String
        return "no_facts" if candidates.empty?
        return "matched" if candidates.any? { |mapping| mapping.status == "matched" }
        return "ambiguous" if candidates.any? { |mapping| mapping.status == "ambiguous" }

        "unmapped"
      end

      private def divergence_for(inventory_status : String, map_status : String) : String
        if inventory_status == "missing" && map_status == "matched"
          "falsely_missing"
        elsif inventory_status == "ported" && (map_status == "unmapped" || map_status == "no_facts")
          "falsely_ported"
        else
          "-"
        end
      end
    end

    module Completion
      extend self

      record StatusEvaluation,
        reachable_ids : Set(String),
        complete_ids : Array(String),
        incomplete_ids : Array(String)

      def evaluate(
        inventory : Array(InventoryRow),
        result : AnalysisResult,
        source_facts : StructuralFacts,
        parity_config : Utils::Config::RepoParityConfig? = nil,
        root_dir : String = ".",
      ) : StatusEvaluation
        reachable_ids = canonical_source_ids(reachable_source_ids(source_facts), parity_config, root_dir)
        rows_by_id = result.rows.to_h { |row| {row.source_id, row} }

        complete_ids = [] of String
        incomplete_ids = [] of String

        inventory.each do |row|
          canonical_id = canonical_source_id(row.source_id, parity_config, root_dir)
          next unless reachable_ids.includes?(canonical_id)

          report = rows_by_id[row.source_id]?
          complete = row.status == "ported" &&
                     report &&
                     report.crystal_name != "-" &&
                     (report.structural_status == "structural_match" || structural_not_applicable_but_matched?(report)) &&
                     (tested_from_refs?(row.crystal_refs) || tested_from_refs?(row.test_refs))

          if complete
            complete_ids << row.source_id
            next
          end

          next if row.status == "intentional_divergence" || row.status == "skipped"
          incomplete_ids << row.source_id
        end

        complete_ids.sort!
        incomplete_ids.sort!

        StatusEvaluation.new(
          reachable_ids: reachable_ids,
          complete_ids: complete_ids,
          incomplete_ids: incomplete_ids,
        )
      end

      def render(
        output : IO,
        inventory : Array(InventoryRow),
        result : AnalysisResult,
        source_facts : StructuralFacts,
        parity_config : Utils::Config::RepoParityConfig? = nil,
        root_dir : String = ".",
      ) : Nil
        status = evaluate(inventory, result, source_facts, parity_config: parity_config, root_dir: root_dir)
        rows_by_id = result.rows.to_h { |row| {row.source_id, row} }

        output.puts "% chiasmus completion facts"
        output.puts "% tested(Id) is inferred from curated crystal_refs that point at spec/ or test/ paths."
        output.puts "% Example queries:"
        output.puts "%   ?- complete(Id)."
        output.puts "%   ?- incomplete(Id)."
        output.puts ":- discontiguous inventory_item/5."
        output.puts ":- discontiguous status/2."
        output.puts ":- discontiguous missing_item/1."
        output.puts ":- discontiguous partial_item/1."
        output.puts ":- discontiguous ported_item/1."
        output.puts ":- discontiguous intentional_divergence/2."
        output.puts ":- discontiguous source_symbol_name/2."
        output.puts ":- discontiguous reachable_from_entry/1."
        output.puts ":- discontiguous tested/1."
        output.puts ":- discontiguous target_match/2."
        output.puts ":- discontiguous structural_ok/1."
        output.puts "missing_item(_) :- fail."
        output.puts "partial_item(_) :- fail."
        output.puts "ported_item(_) :- fail."
        output.puts "intentional_divergence(_, _) :- fail."
        output.puts "reachable_from_entry(_) :- fail."
        output.puts "tested(_) :- fail."
        output.puts "target_match(_, _) :- fail."
        output.puts "structural_ok(_) :- fail."
        output.puts

        inventory.each do |row|
          emit_inventory_facts(output, row)
          output.puts "source_symbol_name(#{quote(row.source_id)}, #{quote(row.source_name)})."
          output.puts "reachable_from_entry(#{quote(row.source_id)})." if status.reachable_ids.includes?(canonical_source_id(row.source_id, parity_config, root_dir))
          output.puts "tested(#{quote(row.source_id)})." if tested_from_refs?(row.crystal_refs) || tested_from_refs?(row.test_refs)

          next unless report = rows_by_id[row.source_id]?

          output.puts "target_match(#{quote(report.source_id)}, #{quote(report.crystal_name)})." unless report.crystal_name == "-"
          if report.structural_status == "structural_match" || structural_not_applicable_but_matched?(report)
            output.puts "structural_ok(#{quote(report.source_id)})."
          end
        end

        render_rules(output)
      end

      private def emit_inventory_facts(output : IO, row : InventoryRow) : Nil
        output.puts "inventory_item(#{quote(row.source_id)}, #{quote(row.kind)}, #{quote(row.status)}, #{quote(row.crystal_refs)}, #{quote(row.notes)})."
        output.puts "status(#{quote(row.source_id)}, #{quote(row.status)})."
        output.puts "missing_item(#{quote(row.source_id)})." if row.status == "missing"
        output.puts "partial_item(#{quote(row.source_id)})." if row.status == "partial"
        output.puts "ported_item(#{quote(row.source_id)})." if row.status == "ported"
        output.puts "intentional_divergence(#{quote(row.source_id)}, #{quote(row.notes)})." if row.status == "intentional_divergence"
      end

      private def structural_not_applicable_but_matched?(report : ReportRow) : Bool
        report.kind == "test" && report.crystal_name != "-"
      end

      private def tested_from_refs?(refs : String) : Bool
        return false if refs == "-"

        refs.split(/[,\s]+/).any? do |token|
          path = token.split(":").first? || token
          path.starts_with?("spec/") || path.includes?("/spec/") ||
            path.starts_with?("test/") || path.includes?("/test/")
        end
      end

      private def reachable_source_ids(source_facts : StructuralFacts) : Set(String)
        return reachable_scoped_source_ids(source_facts) if !source_facts.scoped_calls.empty? && !source_facts.entry_point_files.empty?

        reachable_names = reachable_symbol_keys(source_facts)
        source_ids = Set(String).new
        source_facts.graph.defines.each do |fact|
          next unless reachable_names.includes?(Naming.normalized_key(fact.name))

          source_ids << source_id_for(fact)
        end
        source_ids
      end

      private def reachable_symbol_keys(source_facts : StructuralFacts) : Set(String)
        forward = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
        source_facts.graph.calls.each do |fact|
          forward[fact.caller] << fact.callee
          forward[fact.callee] = Set(String).new unless forward.has_key?(fact.callee)
        end

        roots = source_facts.entry_points.empty? ? source_facts.graph.exports.map(&.name) : source_facts.entry_points
        visited = Set(String).new
        queue = roots.dup

        until queue.empty?
          current = queue.shift
          next if visited.includes?(current)

          visited << current
          forward[current]?.try(&.each do |name|
            queue << name unless visited.includes?(name)
          end)
        end

        visited.map { |name| Naming.normalized_key(name) }.to_set
      end

      private def reachable_scoped_source_ids(source_facts : StructuralFacts) : Set(String)
        forward = Hash(Tuple(String, String), Set(Tuple(String, String))).new do |hash, key|
          hash[key] = Set(Tuple(String, String)).new
        end

        source_facts.scoped_calls.each do |edge|
          caller_key = {edge.file, edge.caller}
          callee_key = resolve_scoped_callee_key(source_facts.graph, edge.file, edge.callee)
          next unless callee_key

          forward[caller_key] << callee_key
          forward[callee_key] = Set(Tuple(String, String)).new unless forward.has_key?(callee_key)
        end

        visited = Set(Tuple(String, String)).new
        queue = [] of Tuple(String, String)

        source_facts.entry_point_files.each do |file, name|
          source_ids_for(graph: source_facts.graph, file: file, name: name).each do |source_id|
            key = source_key_for(source_id)
            next unless visited.add?(key)

            queue << key
          end
        end

        until queue.empty?
          current = queue.shift
          forward[current]?.try &.each do |target|
            next unless visited.add?(target)

            queue << target
          end
        end

        reachable_ids = Set(String).new
        visited.each do |file, name|
          source_ids_for(graph: source_facts.graph, file: file, name: name).each do |source_id|
            reachable_ids << source_id
          end
        end
        reachable_ids
      end

      private def resolve_scoped_callee_key(
        graph : Graph::CodeGraph,
        file : String,
        callee : String,
      ) : Tuple(String, String)?
        local_matches = graph.defines.select { |fact| fact.file == file && fact.name == callee }
        return {file, callee} if local_matches.size == 1

        global_matches = graph.defines.select { |fact| fact.name == callee }
        return {global_matches.first.file, callee} if global_matches.size == 1

        nil
      end

      private def source_ids_for(graph : Graph::CodeGraph, file : String, name : String) : Array(String)
        graph.defines
          .select { |fact| fact.file == file && fact.name == name }
          .map { |fact| source_id_for(fact) }
      end

      private def source_id_for(fact : Graph::DefinesFact) : String
        Graph::IR::Lowering.symbol_id(fact.file, fact.kind, fact.name)
      end

      private def source_key_for(source_id : String) : Tuple(String, String)
        parts = source_id.split("::", 3)
        {parts[0], parts[2]}
      end

      private def render_rules(output : IO) : Nil
        output.puts
        output.puts "complete(Id) :-"
        output.puts "    reachable_from_entry(Id),"
        output.puts "    ported_item(Id),"
        output.puts "    target_match(Id, _),"
        output.puts "    structural_ok(Id),"
        output.puts "    tested(Id)."
        output.puts
        output.puts "incomplete(Id) :-"
        output.puts "    reachable_from_entry(Id),"
        output.puts "    \\+ complete(Id),"
        output.puts "    \\+ intentional_divergence(Id, _),"
        output.puts "    \\+ status(Id, 'skipped')."
      end

      private def canonical_source_ids(ids : Set(String), parity_config : Utils::Config::RepoParityConfig?, root_dir : String) : Set(String)
        ids.map { |id| canonical_source_id(id, parity_config, root_dir) }.to_set
      end

      private def canonical_source_id(source_id : String, parity_config : Utils::Config::RepoParityConfig?, root_dir : String) : String
        parts = source_id.split("::", 3)
        return source_id if parts.size < 3

        "#{canonical_source_file(parts[0], parity_config, root_dir)}::#{parts[1]}::#{parts[2]}"
      end

      private def canonical_source_file(file : String, parity_config : Utils::Config::RepoParityConfig?, root_dir : String) : String
        normalized = file.gsub('\\', '/').gsub(%r{/+}, "/").sub(%r{^\./}, "").sub(%r{/$}, "")
        vendor_src = parity_config.try(&.vendor_src).try(&.strip)
        return normalized unless vendor_src
        return normalized if vendor_src.empty?

        vendor_prefix = vendor_src.gsub('\\', '/').gsub(%r{/+}, "/").sub(%r{^\./}, "").sub(%r{/$}, "")
        repo_prefix = File.expand_path(root_dir).gsub('\\', '/').gsub(%r{/+}, "/").sub(%r{/$}, "")
        if normalized == repo_prefix || normalized.starts_with?("#{repo_prefix}/")
          normalized = normalized[repo_prefix.size..]
          normalized = normalized[1..] if normalized.starts_with?('/')
        end
        return normalized unless normalized == vendor_prefix || normalized.starts_with?("#{vendor_prefix}/")

        suffix = normalized[vendor_prefix.size..]
        suffix = suffix[1..] if suffix.starts_with?('/')
        suffix.empty? ? normalized : suffix
      end

      private def quote(value : String) : String
        escaped = value.gsub("\\", "\\\\").gsub("'", "\\'")
        "'#{escaped}'"
      end
    end

    module CLI
      extend self

      def run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
        inventory_path = ""
        root_dir = "."
        crystal_dirs = [] of String
        rules_path : String? = nil
        map_rules_path : String? = nil
        parser_mode : String? = nil
        source_facts_path : String? = nil
        crystal_facts_path : String? = nil
        source_declarations_path : String? = nil
        target_declarations_path : String? = nil
        bundle_dir : String? = nil
        cache_dir : String? = nil
        format = "tsv"
        help_requested = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: chiasmus-parity --inventory FILE [options]"
          opts.on("--inventory FILE", "Curated port inventory TSV") { |value| inventory_path = value }
          opts.on("--root DIR", "Repo root for relative crystal dirs (default: .)") { |value| root_dir = value }
          opts.on("--crystal-dir DIR", "Crystal source/spec directory (repeatable)") { |value| crystal_dirs << value }
          opts.on("--rules FILE", "Optional conversion rules TSV") { |value| rules_path = value }
          opts.on("--map-rules FILE", "Optional cross-language normalization rules YAML (used with --format maps)") { |value| map_rules_path = value }
          opts.on("--parser MODE", "Parser mode: auto|tree-sitter|regex") { |value| parser_mode = value }
          opts.on("--source-facts FILE", "Optional source graph facts for structural checks") { |value| source_facts_path = value }
          opts.on("--crystal-facts FILE", "Optional Crystal graph facts for structural checks") { |value| crystal_facts_path = value }
          opts.on("--source-declarations FILE", "Optional source typed declarations JSONL for bundle sidecar") { |value| source_declarations_path = value }
          opts.on("--target-declarations FILE", "Optional target typed declarations JSONL for bundle sidecar") { |value| target_declarations_path = value }
          opts.on("--format FORMAT", "Output format: tsv|completion-facts|maps|maps-prolog|surfaces|divergences") { |value| format = value }
          opts.on("--bundle-dir DIR", "Write maps, surfaces, maps-Prolog, and divergences in one reconciliation") { |value| bundle_dir = value }
          opts.on("--cache-dir DIR", "Reuse content-addressed parity bundles in SQLite (bundle mode only)") { |value| cache_dir = value }
          opts.on("--help", "Show this help") do
            help_requested = true
          end
        end

        begin
          parser.parse(args)
        rescue ex
          error.puts ex.message
          error.puts parser
          return 1
        end

        if help_requested
          output.puts parser
          return 0
        end

        if destination = bundle_dir
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if source_path.nil? || crystal_path.nil?
            error.puts "--source-facts and --crystal-facts are required for --bundle-dir"
            return 1
          end
          render_bundle(destination, source_path, crystal_path, inventory_path, map_rules_path, source_declarations_path, target_declarations_path, cache_dir)
          return 0
        end

        if cache_dir
          error.puts "--cache-dir is only supported with --bundle-dir"
          return 1
        end

        if format == "maps"
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if source_path.nil? || crystal_path.nil?
            error.puts "--source-facts and --crystal-facts are required for --format maps"
            return 1
          end
          source_graph = Structural.load_graph(source_path)
          target_graph = Structural.load_graph(crystal_path)
          rules = Rules::RuleSet.load_if(map_rules_path)
          render_maps(output, Reconcile.mappings(source_graph, target_graph, rules), map_rules_path)
          return 0
        end

        if format == "divergences"
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if inventory_path.empty? || source_path.nil? || crystal_path.nil?
            error.puts "--inventory, --source-facts and --crystal-facts are required for --format divergences"
            return 1
          end
          rules = Rules::RuleSet.load_if(map_rules_path)
          mappings = Reconcile.mappings(Structural.load_graph(source_path), Structural.load_graph(crystal_path), rules)
          inventory = Loader.read_inventory(inventory_path)
          render_divergences(output, InventoryJoin.divergences(inventory, mappings, rules))
          return 0
        end

        if format == "maps-prolog"
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if source_path.nil? || crystal_path.nil?
            error.puts "--source-facts and --crystal-facts are required for --format maps-prolog"
            return 1
          end
          rules = Rules::RuleSet.load_if(map_rules_path)
          source_graph = Structural.load_graph(source_path)
          target_graph = Structural.load_graph(crystal_path)
          mappings = Reconcile.mappings(source_graph, target_graph, rules)
          divergences = inventory_path.empty? ? nil : InventoryJoin.divergences(Loader.read_inventory(inventory_path), mappings, rules)
          render_maps_prolog(output, source_graph, target_graph, mappings, divergences, rules)
          return 0
        end

        if format == "surfaces"
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if source_path.nil? || crystal_path.nil?
            error.puts "--source-facts and --crystal-facts are required for --format surfaces"
            return 1
          end
          rules = Rules::RuleSet.load_if(map_rules_path)
          source_graph = Structural.load_graph(source_path)
          target_graph = Structural.load_graph(crystal_path)
          mappings = Reconcile.mappings(source_graph, target_graph, rules)
          render_surfaces(output, Surface.compare(source_graph, target_graph, mappings, rules))
          return 0
        end

        if inventory_path.empty?
          error.puts "--inventory is required"
          error.puts parser
          return 1
        end

        result = Parity.analyze(
          inventory_path: inventory_path,
          root_dir: root_dir,
          crystal_dirs: crystal_dirs,
          rules_path: rules_path,
          parser_mode: parser_mode,
          source_facts_path: source_facts_path,
          crystal_facts_path: crystal_facts_path,
        )

        if format == "completion-facts"
          source_path = source_facts_path
          crystal_path = crystal_facts_path
          if source_path.nil? || crystal_path.nil?
            error.puts "--source-facts and --crystal-facts are required for --format completion-facts"
            return 1
          end
          inventory = Loader.read_inventory(inventory_path)
          Completion.render(output, inventory, result, Structural.load_facts(source_path), root_dir: root_dir)
        else
          render_tsv(output, result)
        end
        0
      rescue ex
        error.puts ex.message
        1
      end

      private def render_tsv(output : IO, result : AnalysisResult) : Nil
        output.puts "# parser_mode=#{result.parser_mode}"
        output.puts "# source_id\tkind\tinventory_status\tmatch_status\tconfidence\tcrystal_name\tcrystal_kind\tcrystal_path\tbasis\tstructural_status\tstructural_details\tnotes"
        result.rows.each do |row|
          output.puts [
            row.source_id,
            row.kind,
            row.inventory_status,
            row.match_status,
            row.confidence.to_s,
            row.crystal_name,
            row.crystal_kind,
            row.crystal_path,
            row.basis,
            row.structural_status,
            row.structural_details,
            row.notes,
          ].join('\t')
        end
      end

      private def render_bundle(
        destination : String,
        source_path : String,
        crystal_path : String,
        inventory_path : String,
        rules_path : String?,
        source_declarations_path : String?,
        target_declarations_path : String?,
        cache_dir : String? = nil,
      ) : Nil
        input_paths = [source_path, crystal_path, inventory_path.empty? ? nil : inventory_path, rules_path, source_declarations_path, target_declarations_path]
        initial_fingerprint = cache_dir.try { BundleCache.fingerprint(input_paths) }
        if directory = cache_dir
          if fingerprint = initial_fingerprint
            if cache = BundleCache.load(directory, input_paths, fingerprint)
              if BundleCache.fingerprint(input_paths) == fingerprint
                write_bundle(destination, cache)
                return
              end
            end
          end
        end

        source_graph = Structural.load_graph(source_path)
        target_graph = Structural.load_graph(crystal_path)
        rules = Rules::RuleSet.load_if(rules_path)
        mappings = Reconcile.mappings(source_graph, target_graph, rules)
        source_typed = PortConcepts::TypedIndex.load(source_declarations_path, rules.source_language)
        target_typed = PortConcepts::TypedIndex.load(target_declarations_path, rules.target_language)
        surfaces = Surface.compare(source_graph, target_graph, mappings, rules)
        divergences = inventory_path.empty? ? nil : InventoryJoin.divergences(Loader.read_inventory(inventory_path), mappings, rules)

        Dir.mkdir_p(destination)
        if directory = cache_dir
          artifacts = {} of String => String
          artifacts["maps.tsv"] = render_to_string { |report| render_maps(report, mappings, rules_path) }
          artifacts["surfaces.tsv"] = render_to_string { |report| render_surfaces(report, surfaces) }
          artifacts["maps.pl"] = render_to_string { |report| render_maps_prolog(report, source_graph, target_graph, mappings, divergences, rules, surfaces) }
          artifacts["port-concepts.jsonl"] = render_to_string { |report| PortConcepts.render(report, mappings, source_graph, target_graph, rules, source_typed, target_typed) }
          if rows = divergences
            artifacts["divergences.tsv"] = render_to_string { |report| render_divergences(report, rows) }
          end
          if fingerprint = initial_fingerprint
            BundleCache.save(directory, input_paths, artifacts, fingerprint) if BundleCache.fingerprint(input_paths) == fingerprint
          end
          write_bundle(destination, artifacts)
        else
          File.open(File.join(destination, "maps.tsv"), "w") { |report| render_maps(report, mappings, rules_path) }
          File.open(File.join(destination, "surfaces.tsv"), "w") { |report| render_surfaces(report, surfaces) }
          File.open(File.join(destination, "maps.pl"), "w") { |report| render_maps_prolog(report, source_graph, target_graph, mappings, divergences, rules, surfaces) }
          File.open(File.join(destination, "port-concepts.jsonl"), "w") { |report| PortConcepts.render(report, mappings, source_graph, target_graph, rules, source_typed, target_typed) }
          if rows = divergences
            File.open(File.join(destination, "divergences.tsv"), "w") { |report| render_divergences(report, rows) }
          else
            delete_divergences(destination)
          end
        end
      end

      private def render_to_string(& : IO ->) : String
        output = IO::Memory.new
        yield output
        output.to_s
      end

      private def write_bundle(destination : String, artifacts : Hash(String, String)) : Nil
        Dir.mkdir_p(destination)
        delete_divergences(destination) unless artifacts.has_key?("divergences.tsv")
        artifacts.each do |name, content|
          File.write(File.join(destination, name), content)
        end
      end

      private def delete_divergences(destination : String) : Nil
        path = File.join(destination, "divergences.tsv")
        File.delete(path) if File.file?(path)
      end

      private def render_maps(output : IO, mappings : Array(Reconcile::Mapping), rules_path : String?) : Nil
        counts = Hash(String, Int32).new(0)
        mappings.each { |mapping| counts[mapping.status] += 1 }

        output.puts "# rules=#{rules_path || "-"}"
        output.puts "# total=#{mappings.size} matched=#{counts["matched"]} ambiguous=#{counts["ambiguous"]} unmapped=#{counts["unmapped_source"]}"
        output.puts "source_id\tsource_name\tsource_kind\tsource_owner\tcanonical\ttarget_id\ttarget_name\ttarget_kind\ttarget_owner\tstatus\tbasis"
        mappings.each do |mapping|
          output.puts [
            mapping.source_id,
            mapping.source_name,
            mapping.source_kind,
            mapping.source_owner || "-",
            mapping.canonical,
            mapping.target_id || "-",
            mapping.target_name || "-",
            mapping.target_kind || "-",
            mapping.target_owner || "-",
            mapping.status,
            mapping.basis,
          ].join('\t')
        end
      end

      private def render_divergences(output : IO, rows : Array(InventoryJoin::DivergenceRow)) : Nil
        falsely_missing = rows.count { |row| row.divergence == "falsely_missing" }
        falsely_ported = rows.count { |row| row.divergence == "falsely_ported" }

        output.puts "# falsely_missing=#{falsely_missing} falsely_ported=#{falsely_ported} total=#{rows.size}"
        output.puts "source_id\tkind\tinventory_status\tmap_status\tdivergence\ttarget_name\ttarget_id\ttarget_file\ttarget_owner\tbasis"
        rows.each do |row|
          output.puts [
            row.source_id,
            row.kind,
            row.inventory_status,
            row.map_status,
            row.divergence,
            row.target_name,
            row.target_id || "-",
            row.target_file || "-",
            row.target_owner || "-",
            row.basis,
          ].join('\t')
        end
      end

      private def render_surfaces(output : IO, reports : Array(Surface::SurfaceReport)) : Nil
        counts = Hash(String, Int32).new(0)
        reports.each { |report| counts[report.status] += 1 }

        output.puts "# surface_match=#{counts["surface_match"]} surface_mismatch=#{counts["surface_mismatch"]} surface_unmodeled=#{counts["surface_unmodeled"]} total=#{reports.size}"
        output.puts "source_id\ttarget_id\tstatus\tsource_arity\ttarget_arity\tsource_return\ttarget_return\treturn_match\tdetails"
        reports.each do |report|
          output.puts [
            report.source_id,
            report.target_id || "-",
            report.status,
            report.source_arity.to_s,
            report.target_arity.to_s,
            report.source_return || "-",
            report.target_return || "-",
            report.return_type_match.to_s,
            report.details,
          ].join('\t')
        end
      end

      MAPS_QUERY_RULES = <<-PROLOG
      % --- chiasmus parity query rules -------------------------------------------
      maps_to_matched(Id) :- maps_to(Id, Target), Target \\= none.
      inventory_matched(Id) :- inventory_entity(Id, Entity), map_status(Entity, matched).
      inventory_unmapped(Id) :- inventory_entity(Id, Entity), map_status(Entity, unmapped_source),
          \\+ inventory_matched(Id).
      falsely_missing(Id) :- inventory_item(Id, _, missing, _, _), inventory_matched(Id).
      falsely_ported(Id) :- inventory_item(Id, _, ported, _, _),
          ( \\+ inventory_entity(Id, _) ; inventory_unmapped(Id) ).
      unmapped_source(Id) :- source_entity(Id), \\+ maps_to(Id, _).
      renamed_but_present(S, T) :- maps_to(S, T), T \\= none,
          entity(S, _, NS, _, _), entity(T, _, NT, _, _), NS \\= NT.
      surface_drift(Entity) :- surface_status(Entity, surface_mismatch).
      surface_ok(Id) :- \\+ (inventory_entity(Id, Entity), surface_drift(Entity)).
      % Structural completion gate, foldable with chiasmus-complete.
      complete(Id) :- inventory_item(Id, _, ported, _, _), inventory_matched(Id), surface_ok(Id).
      incomplete(Id) :- inventory_item(Id, _, Status, _, _),
          Status \\= skipped, Status \\= intentional_divergence, \\+ complete(Id).
      % --- end query rules -------------------------------------------------------
      PROLOG

      private def render_maps_prolog(
        output : IO,
        source : Graph::CodeGraph,
        target : Graph::CodeGraph,
        mappings : Array(Reconcile::Mapping),
        divergences : Array(InventoryJoin::DivergenceRow)?,
        rules : Rules::RuleSet,
        surfaces : Array(Surface::SurfaceReport)? = nil,
      ) : Nil
        normalizer = Rules::Normalizer.new(rules)
        source_lang = rules.source_language.empty? ? "source" : rules.source_language
        target_lang = rules.target_language.empty? ? "target" : rules.target_language

        output.puts "% maps-prolog generated by chiasmus-parity"
        output.puts "% source_language=#{source_lang} target_language=#{target_lang}"
        output.puts

        source_owners = Reconcile.owners(source, rules, Rules::Normalizer::Side::Source)
        target_owners = Reconcile.owners(target, rules, Rules::Normalizer::Side::Target)

        source.defines.each do |fact|
          id = Reconcile.entity_id(fact)
          output.puts "entity(#{atom(id)}, #{atom(fact.kind.to_s.downcase)}, #{atom(Reconcile.display_name(fact))}, #{atom(source_owners[id]? || "none")}, #{source_lang})."
        end
        target.defines.each do |fact|
          id = Reconcile.entity_id(fact)
          output.puts "entity(#{atom(id)}, #{atom(fact.kind.to_s.downcase)}, #{atom(Reconcile.display_name(fact))}, #{atom(target_owners[id]? || "none")}, #{target_lang})."
        end

        source.defines.each do |fact|
          id = Reconcile.entity_id(fact)
          output.puts "normalized(#{atom(id)}, #{atom(normalizer.canonical(Rules::Normalizer::Side::Source, Reconcile.display_name(fact)))})."
        end
        target.defines.each do |fact|
          id = Reconcile.entity_id(fact)
          output.puts "normalized(#{atom(id)}, #{atom(normalizer.canonical(Rules::Normalizer::Side::Target, Reconcile.display_name(fact)))})."
        end

        source.defines.each { |fact| output.puts "source_entity(#{atom(Reconcile.entity_id(fact))})." }
        target.defines.each { |fact| output.puts "target_entity(#{atom(Reconcile.entity_id(fact))})." }

        mappings.each do |mapping|
          target_id = mapping.target_id
          output.puts "maps_to(#{atom(mapping.source_id)}, #{target_id ? atom(target_id) : "none"})."
        end
        mappings.each do |mapping|
          output.puts "map_status(#{atom(mapping.source_id)}, #{atom(mapping.status)})."
        end

        (surfaces || Surface.compare(source, target, mappings, rules)).each do |report|
          output.puts "surface_status(#{atom(report.source_id)}, #{atom(report.status)})."
        end

        rules.renames.each { |rename| output.puts "rename(#{atom(rename.source)}, #{atom(rename.target)})." }
        rules.consolidate.each { |rule| output.puts "consolidate(#{atom(rule.source)}, #{atom(rule.target)})." }
        rules.owner_aliases.each { |alias_rule| output.puts "owner_alias(#{atom(alias_rule.source)}, #{atom(alias_rule.target)})." }

        emit_members(output, source)
        emit_members(output, target)

        if rows = divergences
          rows.each do |row|
            output.puts "inventory_item(#{atom(row.source_id)}, #{atom(row.kind)}, #{atom(row.inventory_status)}, -, -)."
          end
          rows.each do |row|
            entity_id = row.entity_id
            output.puts "inventory_entity(#{atom(row.source_id)}, #{atom(entity_id)})." if entity_id
          end
          rows.each do |row|
            output.puts "divergence(#{atom(row.source_id)}, #{atom(row.divergence)}, #{atom(row.target_name)})." unless row.divergence == "-"
          end
        end

        output.puts
        output.puts MAPS_QUERY_RULES
      end

      private def emit_members(output : IO, graph : Graph::CodeGraph) : Nil
        graph.contains.each do |fact|
          output.puts "member(#{atom(fact.parent)}, #{atom(fact.child)}, member)."
        end
      end

      private def atom(value : String) : String
        return value if value.matches?(/^[a-z][a-z0-9_]*$/)

        "'#{value.gsub("'", "''")}'"
      end
    end

    def self.parallel_map(items : Array(T), max_concurrency : Int32 = MAX_CONCURRENCY, &block : T -> U) : Array(U) forall T, U
      Utils::BoundedWork.map_ordered_or_raise(items, max_concurrency, parallel: parallel_enabled?) do |item|
        block.call(item)
      end
    end

    def self.parallel_enabled? : Bool
      ENV["CHIASMUS_PARITY_PARALLEL"]? == "1"
    end
  end
end
