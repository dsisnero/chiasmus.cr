require "option_parser"
require "set"
require "./discovery"
require "./graph/types"
require "./utils/bounded_work"

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

    MAX_CONCURRENCY = Math.max(System.cpu_count, 2)

    record InventoryRow,
      source_id : String,
      kind : String,
      status : String,
      crystal_refs : String,
      notes : String do
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
      entry_points : Array(String)

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
          InventoryRow.new(
            source_id: cols[0],
            kind: cols[1],
            status: cols[2],
            crystal_refs: empty_to_dash(cols[3]),
            notes: empty_to_dash(cols[4]),
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
      ) : StructuralReport
        source_defined = defined?(source_graph, source_symbol)
        target_defined = defined?(target_graph, target_symbol)
        source_exported = exported?(source_graph, source_symbol)
        target_exported = exported?(target_graph, target_symbol)
        source_entry_point = entry_point?(source_symbol, source_entry_points)
        target_entry_point = entry_point?(target_symbol, target_entry_points)
        source_imports = normalized_imports(source_graph, source_symbol)
        target_imports = normalized_imports(target_graph, target_symbol)
        source_callees = normalized_callees(source_graph, source_symbol)
        target_callees = normalized_callees(target_graph, target_symbol)
        source_contains = normalized_contains(source_graph, source_symbol)
        target_contains = normalized_contains(target_graph, target_symbol)

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
          missing_calls.empty? &&
          extra_calls.empty? &&
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
        defines = [] of Graph::DefinesFact
        calls = [] of Graph::CallsFact
        imports = [] of Graph::ImportsFact
        exports = [] of Graph::ExportsFact
        contains = [] of Graph::ContainsFact
        entry_points = [] of String

        File.each_line(path) do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.starts_with?('%') || stripped.starts_with?(":-")
          if stripped.starts_with?("defines(")
            args = parse_args(stripped["defines(".size...-2])
            defines << Graph::DefinesFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
              kind: parse_symbol_kind(atom(args[2])),
              line: args[3].to_i,
              end_line: args[4].to_i,
            )
          elsif stripped.starts_with?("calls(")
            args = parse_args(stripped["calls(".size...-2])
            calls << Graph::CallsFact.new(
              caller: atom(args[0]),
              callee: atom(args[1]),
            )
          elsif stripped.starts_with?("imports(")
            args = parse_args(stripped["imports(".size...-2])
            imports << Graph::ImportsFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
              source: atom(args[2]),
            )
          elsif stripped.starts_with?("exports(")
            args = parse_args(stripped["exports(".size...-2])
            exports << Graph::ExportsFact.new(
              file: atom(args[0]),
              name: atom(args[1]),
            )
          elsif stripped.starts_with?("contains(")
            args = parse_args(stripped["contains(".size...-2])
            contains << Graph::ContainsFact.new(
              parent: atom(args[0]),
              child: atom(args[1]),
            )
          elsif stripped.starts_with?("entry_point(")
            args = parse_args(stripped["entry_point(".size...-2])
            entry_points << atom(args[0])
          end
        end

        StructuralFacts.new(
          graph: Graph::CodeGraph.new(
            defines: defines,
            calls: calls,
            imports: imports,
            exports: exports,
            contains: contains,
          ),
          entry_points: normalized_entry_points(entry_points),
        )
      end

      def load_graph(path : String) : Graph::CodeGraph
        load_facts(path).graph
      end

      private def defined?(graph : Graph::CodeGraph, symbol : String) : Bool
        graph.defines.any? { |fact| fact.name == symbol }
      end

      private def exported?(graph : Graph::CodeGraph, symbol : String) : Bool
        normalized_symbol = Naming.normalized_simple(symbol)
        graph.exports.any? { |fact| Naming.normalized_simple(fact.name) == normalized_symbol }
      end

      private def entry_point?(symbol : String, entry_points : Array(String)?) : Bool
        return false unless entry_points

        normalized_symbol = Naming.normalized_simple(symbol)
        entry_points.any? { |name| Naming.normalized_simple(name) == normalized_symbol }
      end

      private def normalized_imports(graph : Graph::CodeGraph, symbol : String) : Array(String)
        file = defining_file(graph, symbol)
        return [] of String unless file

        imports = graph.imports.select { |fact| fact.file == file }
          .map { |fact| normalized_import_target(fact) }
          .reject(&.empty?)
        imports.uniq!
        imports.sort!
        imports
      end

      private def defining_file(graph : Graph::CodeGraph, symbol : String) : String?
        graph.defines.find { |fact| fact.name == symbol }.try(&.file)
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

      private def normalized_callees(graph : Graph::CodeGraph, symbol : String) : Array(String)
        callees = graph.calls.select { |fact| fact.caller == symbol }
          .map { |fact| Naming.normalized_simple(fact.callee) }
          .reject(&.empty?)
        callees.uniq!
        callees.sort!
        callees
      end

      private def normalized_contains(graph : Graph::CodeGraph, symbol : String) : Array(String)
        contained = graph.contains.select { |fact| fact.parent == symbol }
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
    end

    class CrystalScanner
      def self.scan(root_dir : String, dirs : Array(String), parser_mode : String? = nil) : Tuple(Array(SymbolItem), String)
        force = parser_mode.try(&.downcase)
        register_vendor_grammars(root_dir)
        regex_items = regex_scan(root_dir, dirs)

        if force == "tree-sitter"
          items = tree_sitter_scan(root_dir, dirs, "tree-sitter")
          return {deduplicate(items + regex_items), "tree-sitter+regex"}
        end

        if force != "regex" && Discovery.tree_sitter_available?("crystal")
          begin
            items = tree_sitter_scan(root_dir, dirs, nil)
            return {deduplicate(items + regex_items), "tree-sitter+regex"}
          rescue ex
            # Keep the report usable when discovery cannot parse the workspace.
          end
        end

        {regex_items, "regex"}
      end

      private def self.register_vendor_grammars(root_dir : String) : Nil
        vendor_dir = File.join(root_dir, "vendor", "grammars")
        Discovery.register_grammar_directory(vendor_dir) if Dir.exists?(vendor_dir)
      end

      private def self.tree_sitter_scan(root_dir : String, dirs : Array(String), force_parser : String?) : Array(SymbolItem)
        files = collect_files(root_dir, dirs)
        result = Discovery.discover_files("crystal", files, force_parser: force_parser)
        result.items.compact_map do |item|
          next unless allowed_kind?(item.kind)
          SymbolItem.new(
            id: item.id,
            name: item.name,
            kind: item.kind,
            file: item.file,
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
        crystal_file_paths(absolute_root, dirs).compact_map do |path|
          rel = relative_to_root(path, absolute_root)
          begin
            {rel, File.read(path)}
          rescue ex
            nil
          end
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

      private def self.deduplicate(items : Array(SymbolItem)) : Array(SymbolItem)
        seen = Set(String).new
        items.select { |item| seen.add?(item.id) }
      end

      private def self.crystal_file_paths(absolute_root : String, dirs : Array(String)) : Array(String)
        files = [] of String
        dirs.each do |dir|
          abs_dir = File.expand_path(dir, absolute_root)
          next unless Dir.exists?(abs_dir)

          Dir.glob(File.join(abs_dir, "**", "*.cr")).sort!.each do |path|
            next unless File.file?(path)
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
      def initialize(
        @symbols : Array(SymbolItem),
        @rules : Array(ConversionRule),
        @source_graph : Graph::CodeGraph? = nil,
        @crystal_graph : Graph::CodeGraph? = nil,
        @source_entry_points : Array(String)? = nil,
        @crystal_entry_points : Array(String)? = nil,
      )
        @symbols_by_file = Hash(String, Array(SymbolItem)).new { |hash, key| hash[key] = [] of SymbolItem }
        @rules_by_upstream = Hash(String, Array(ConversionRule)).new { |hash, key| hash[key] = [] of ConversionRule }

        @symbols.each do |symbol|
          @symbols_by_file[symbol.file] << symbol
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
        structural_status, structural_details = structural_fields(row.source_name, match.symbol.name, row.status)
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
        structural_status, structural_details = structural_fields(row.source_name, symbol.name, row.status)
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

        refs.split(/[\s,]+/).compact_map do |token|
          stripped = token.strip
          next if stripped.empty? || stripped == "-"
          path = stripped.split(":").first
          next unless path.ends_with?(".cr")
          path
        end
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
            structural_status: structural_fields(row.source_name, match.symbol.name, row.status)[0],
            structural_details: structural_fields(row.source_name, match.symbol.name, row.status)[1],
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

      private def structural_fields(source_symbol : String, crystal_symbol : String, inventory_status : String) : Tuple(String, String)
        return {"-", "-"} if inventory_status == "intentional_divergence"
        source_graph = @source_graph
        crystal_graph = @crystal_graph
        return {"-", "-"} unless source_graph && crystal_graph

        report = Structural.compare(
          source_graph,
          source_symbol,
          crystal_graph,
          crystal_symbol,
          source_entry_points: @source_entry_points,
          target_entry_points: @crystal_entry_points,
        )
        details = structural_detail_lines(report)
        {report.status, details.empty? ? "-" : details.join("; ")}
      end

      private def structural_detail_lines(report : StructuralReport) : Array(String)
        details = [] of String
        append_presence_details(details, report)
        append_relation_details(details, "imports", report.matched_imports, report.missing_imports, report.extra_imports)
        append_relation_details(details, "calls", report.matched_calls, report.missing_calls, report.extra_calls)
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
        matches = symbols.compact_map do |symbol|
          score_match(row, symbol)
        end
        matches.sort_by! { |match| {-match.score, match.symbol.file, match.symbol.name} }
        matches
      end

      private def score_match(row : InventoryRow, symbol : SymbolItem) : Match?
        source_name = row.source_name
        source_key = Naming.normalized_key(source_name)
        source_simple = Naming.normalized_simple(source_name)
        source_owner = Naming.normalized_owner(source_name)
        symbol_key = Naming.normalized_key(symbol.name)
        symbol_simple = Naming.normalized_simple(symbol.name)
        symbol_owner = Naming.normalized_owner(symbol.name)

        return nil if source_simple.empty? || symbol_simple.empty?

        if match = constructor_owner_match(source_name, symbol, symbol_simple)
          return match
        end

        score, basis = name_score(row, symbol, source_name, source_key, source_simple, source_owner, symbol_key, symbol_simple, symbol_owner)

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
        source_name : String,
        source_key : String,
        source_simple : String,
        source_owner : String,
        symbol_key : String,
        symbol_simple : String,
        symbol_owner : String,
      ) : Tuple(Int32, String)
        if row.kind == "test"
          return {100, "exact"} if source_key == symbol_key
          return {0, "simple_name"}
        end

        return {100, "exact"} if source_name == symbol.name
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
    end

    def self.analyze(
      inventory_path : String,
      root_dir : String = ".",
      crystal_dirs : Array(String) = ["src"],
      rules_path : String? = nil,
      parser_mode : String? = nil,
      source_facts_path : String? = nil,
      crystal_facts_path : String? = nil,
    ) : AnalysisResult
      inventory = Loader.read_inventory(inventory_path)
      rules = Loader.read_rules(rules_path)
      symbols, parser = CrystalScanner.scan(root_dir, crystal_dirs, parser_mode)
      source_facts = source_facts_path ? Structural.load_facts(source_facts_path) : nil
      crystal_facts = crystal_facts_path ? Structural.load_facts(crystal_facts_path) : nil
      matcher = Matcher.new(
        symbols,
        rules,
        source_graph: source_facts.try(&.graph),
        crystal_graph: crystal_facts.try(&.graph),
        source_entry_points: source_facts.try(&.entry_points),
        crystal_entry_points: crystal_facts.try(&.entry_points),
      )
      AnalysisResult.new(rows: matcher.analyze(inventory), parser_mode: parser)
    end

    module Completion
      extend self

      def render(output : IO, inventory : Array(InventoryRow), result : AnalysisResult, source_facts : StructuralFacts) : Nil
        reachable = reachable_symbol_keys(source_facts)
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
          output.puts "reachable_from_entry(#{quote(row.source_id)})." if reachable.includes?(Naming.normalized_key(row.source_name))
          output.puts "tested(#{quote(row.source_id)})." if tested_from_refs?(row.crystal_refs)

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
        parser_mode : String? = nil
        source_facts_path : String? = nil
        crystal_facts_path : String? = nil
        format = "tsv"
        help_requested = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: chiasmus-parity --inventory FILE [options]"
          opts.on("--inventory FILE", "Curated port inventory TSV") { |value| inventory_path = value }
          opts.on("--root DIR", "Repo root for relative crystal dirs (default: .)") { |value| root_dir = value }
          opts.on("--crystal-dir DIR", "Crystal source/spec directory (repeatable)") { |value| crystal_dirs << value }
          opts.on("--rules FILE", "Optional conversion rules TSV") { |value| rules_path = value }
          opts.on("--parser MODE", "Parser mode: auto|tree-sitter|regex") { |value| parser_mode = value }
          opts.on("--source-facts FILE", "Optional source graph facts for structural checks") { |value| source_facts_path = value }
          opts.on("--crystal-facts FILE", "Optional Crystal graph facts for structural checks") { |value| crystal_facts_path = value }
          opts.on("--format FORMAT", "Output format: tsv|completion-facts") { |value| format = value }
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

        if inventory_path.empty?
          error.puts "--inventory is required"
          error.puts parser
          return 1
        end

        crystal_dirs = ["src", "spec"] if crystal_dirs.empty?

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
          Completion.render(output, inventory, result, Structural.load_facts(source_path))
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
    end

    def self.parallel_map(items : Array(T), max_concurrency : Int32 = MAX_CONCURRENCY, &block : T -> U) : Array(U) forall T, U
      Utils::BoundedWork.map_ordered_or_raise(items, max_concurrency) do |item|
        block.call(item)
      end
    end
  end
end
