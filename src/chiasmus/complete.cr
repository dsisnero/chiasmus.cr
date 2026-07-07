require "option_parser"
require "./parity"
require "./solvers/prolog_solver"

module Chiasmus
  module Complete
    enum QueryMode
      Status
      Complete
      Incomplete
    end

    enum OutputFormat
      Tsv
      Ids
    end

    record Evaluation,
      analysis : Parity::AnalysisResult,
      complete_ids : Array(String),
      incomplete_ids : Array(String)

    extend self

    def evaluate(
      inventory_path : String,
      source_facts_path : String,
      crystal_facts_path : String? = nil,
      parity_report_path : String? = nil,
      root_dir : String = ".",
      crystal_dirs : Array(String) = ["src", "spec"],
      rules_path : String? = nil,
      parser_mode : String? = nil,
    ) : Evaluation
      analysis = if parity_report_path
                   Parity::Loader.read_report(parity_report_path)
                 else
                   facts_path = crystal_facts_path || raise ArgumentError.new("crystal_facts_path is required when parity_report_path is not provided")
                   Parity.analyze(
                     inventory_path: inventory_path,
                     root_dir: root_dir,
                     crystal_dirs: crystal_dirs,
                     rules_path: rules_path,
                     parser_mode: parser_mode,
                     source_facts_path: source_facts_path,
                     crystal_facts_path: facts_path,
                   )
                 end
      inventory = Parity::Loader.read_inventory(inventory_path)
      source_facts = Parity::Structural.load_facts(source_facts_path)
      program = IO::Memory.new
      Parity::Completion.render(program, inventory, analysis, source_facts)

      solver = Solvers::PrologSolver.new
      begin
        complete_ids = query_ids(solver, program.to_s, "complete(Id)")
        incomplete_ids = query_ids(solver, program.to_s, "incomplete(Id)")
      ensure
        solver.dispose
      end

      Evaluation.new(
        analysis: analysis,
        complete_ids: complete_ids,
        incomplete_ids: incomplete_ids,
      )
    end

    private def query_ids(solver : Solvers::PrologSolver, program : String, query : String) : Array(String)
      result = solver.solve(program, query)
      case result
      when Solvers::SuccessResult
        ids = result.answers.compact_map { |answer| answer.bindings["Id"]? }
        ids.sort!
        ids
      when Solvers::ErrorResult
        raise result.error
      else
        raise "Unexpected Prolog result for #{query}"
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
        source_facts_path = ""
        crystal_facts_path = ""
        parity_report_path : String? = nil
        query_mode = QueryMode::Status
        format = OutputFormat::Tsv
        help_requested = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: chiasmus-complete --inventory FILE --source-facts FILE [--crystal-facts FILE | --parity-report FILE] [options]"
          opts.on("--inventory FILE", "Curated port inventory TSV") { |value| inventory_path = value }
          opts.on("--root DIR", "Repo root for relative crystal dirs (default: .)") { |value| root_dir = value }
          opts.on("--crystal-dir DIR", "Crystal source/spec directory (repeatable)") { |value| crystal_dirs << value }
          opts.on("--rules FILE", "Optional conversion rules TSV") { |value| rules_path = value }
          opts.on("--parser MODE", "Parser mode: auto|tree-sitter|regex") { |value| parser_mode = value }
          opts.on("--source-facts FILE", "Source graph facts") { |value| source_facts_path = value }
          opts.on("--crystal-facts FILE", "Crystal graph facts") { |value| crystal_facts_path = value }
          opts.on("--parity-report FILE", "Precomputed parity TSV report") { |value| parity_report_path = value }
          opts.on("--query MODE", "Query mode: status|complete|incomplete") { |value| query_mode = parse_query_mode(value) }
          opts.on("--format FORMAT", "List output format: tsv|ids") { |value| format = parse_format(value) }
          opts.on("--help", "Show this help") { help_requested = true }
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

        if source_facts_path.empty?
          error.puts "--source-facts is required"
          error.puts parser
          return 1
        end

        if parity_report_path.nil? && crystal_facts_path.empty?
          error.puts "--crystal-facts is required unless --parity-report is provided"
          error.puts parser
          return 1
        end

        crystal_dirs = ["src", "spec"] if crystal_dirs.empty?

        evaluation = Complete.evaluate(
          inventory_path: inventory_path,
          root_dir: root_dir,
          crystal_dirs: crystal_dirs,
          rules_path: rules_path,
          parser_mode: parser_mode,
          source_facts_path: source_facts_path,
          crystal_facts_path: crystal_facts_path,
          parity_report_path: parity_report_path,
        )

        case query_mode
        in .status?
          render_status(output, evaluation)
          evaluation.incomplete_ids.empty? ? 0 : 2
        in .complete?
          render_rows(output, evaluation, evaluation.complete_ids, format)
          0
        in .incomplete?
          render_rows(output, evaluation, evaluation.incomplete_ids, format)
          0
        end
      rescue ex
        error.puts ex.message
        1
      end

      private def parse_query_mode(value : String) : QueryMode
        case value.downcase
        when "status"     then QueryMode::Status
        when "complete"   then QueryMode::Complete
        when "incomplete" then QueryMode::Incomplete
        else
          raise "Unsupported query mode: #{value}"
        end
      end

      private def parse_format(value : String) : OutputFormat
        case value.downcase
        when "tsv" then OutputFormat::Tsv
        when "ids" then OutputFormat::Ids
        else
          raise "Unsupported format: #{value}"
        end
      end

      private def render_status(output : IO, evaluation : Evaluation) : Nil
        output.puts "status\t#{evaluation.incomplete_ids.empty? ? "complete" : "incomplete"}"
        output.puts "complete_count\t#{evaluation.complete_ids.size}"
        output.puts "incomplete_count\t#{evaluation.incomplete_ids.size}"
      end

      private def render_rows(output : IO, evaluation : Evaluation, ids : Array(String), format : OutputFormat) : Nil
        case format
        in .ids?
          ids.each { |id| output.puts id }
        in .tsv?
          rows = select_rows(evaluation.analysis.rows, ids)
          output.puts "# source_id\tkind\tinventory_status\tmatch_status\tstructural_status\tcrystal_path\tnotes"
          rows.each do |row|
            output.puts [
              row.source_id,
              row.kind,
              row.inventory_status,
              row.match_status,
              row.structural_status,
              row.crystal_path,
              row.notes,
            ].join('\t')
          end
        end
      end

      private def select_rows(rows : Array(Parity::ReportRow), ids : Array(String)) : Array(Parity::ReportRow)
        ids_set = ids.to_set
        rows.select { |row| ids_set.includes?(row.source_id) }
      end
    end
  end
end
