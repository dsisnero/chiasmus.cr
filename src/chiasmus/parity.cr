require "option_parser"
require "set"
require "./discovery"
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
      notes : String

    record AnalysisResult,
      rows : Array(ReportRow),
      parser_mode : String

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
      def initialize(@symbols : Array(SymbolItem), @rules : Array(ConversionRule))
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
          notes: notes,
        )
      end

      private def report_from_symbol(row : InventoryRow, status : String, symbol : SymbolItem, notes : String, confidence : Int32 = 100, basis : String = "ref_path") : ReportRow
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
    ) : AnalysisResult
      inventory = Loader.read_inventory(inventory_path)
      rules = Loader.read_rules(rules_path)
      symbols, parser = CrystalScanner.scan(root_dir, crystal_dirs, parser_mode)
      matcher = Matcher.new(symbols, rules)
      AnalysisResult.new(rows: matcher.analyze(inventory), parser_mode: parser)
    end

    module CLI
      extend self

      def run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
        inventory_path = ""
        root_dir = "."
        crystal_dirs = [] of String
        rules_path : String? = nil
        parser_mode : String? = nil
        help_requested = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: chiasmus-parity --inventory FILE [options]"
          opts.on("--inventory FILE", "Curated port inventory TSV") { |value| inventory_path = value }
          opts.on("--root DIR", "Repo root for relative crystal dirs (default: .)") { |value| root_dir = value }
          opts.on("--crystal-dir DIR", "Crystal source/spec directory (repeatable)") { |value| crystal_dirs << value }
          opts.on("--rules FILE", "Optional conversion rules TSV") { |value| rules_path = value }
          opts.on("--parser MODE", "Parser mode: auto|tree-sitter|regex") { |value| parser_mode = value }
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
        )

        render_tsv(output, result)
        0
      rescue ex
        error.puts ex.message
        1
      end

      private def render_tsv(output : IO, result : AnalysisResult) : Nil
        output.puts "# parser_mode=#{result.parser_mode}"
        output.puts "# source_id\tkind\tinventory_status\tmatch_status\tconfidence\tcrystal_name\tcrystal_kind\tcrystal_path\tbasis\tnotes"
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
