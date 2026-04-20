require "./types"
require "./session"
require "crolog"

module Chiasmus
  module Solvers
    class PrologSolver < Solver
      MAX_TRACE_ENTRIES = 500

      def type : SolverType
        SolverType::Prolog
      end

      def solve(input : SolverInput) : SolverResult
        return ErrorResult.new("Expected prolog input type") unless input.is_a?(PrologSolverInput)

        solve(input.program, input.query, input.explain)
      end

      def solve(program : String, query : String, explain : Bool = false) : SolverResult
        Session.instance.solve_prolog(program, query, explain)
      end

      def solve_async(program : String, query : String, explain : Bool = false) : Channel(SolverResult)
        Session.instance.solve_prolog_async(program, query, explain)
      end

      def dispose : Nil
      end
    end

    class PrologRuntime
      MAX_TRACE_ENTRIES = PrologSolver::MAX_TRACE_ENTRIES

      @@init_lock = Mutex.new
      @@initialized = false
      @@module_counter = Atomic(Int64).new(0_i64)

      def initialize
        self.class.ensure_initialized
      end

      def self.ensure_initialized : Nil
        @@init_lock.synchronize do
          return if @@initialized

          Crolog.init_with_argv("chiasmus", "--quiet")
          @@initialized = true
        end
      end

      def solve(program : String, query : String, explain : Bool) : SolverResult
        source = explain ? instrument_for_tracing(program) : program
        temp_file = write_program(source)
        temp_path = temp_file.path
        module_name = next_module_name

        consult_result = call_goal("load_files(#{quote_atom(temp_path)}, [module(#{module_name}), silent(true)])")
        return ErrorResult.new(consult_result) if consult_result

        variables = extract_query_variables(query)
        results = run_findall(module_name, query, variables)
        if error = results.error
          return ErrorResult.new(error)
        end

        answers = build_answers(results.rows, variables)
        trace = explain ? collect_trace(module_name) : nil
        SuccessResult.new(answers, trace)
      ensure
        unload_file(temp_path) if temp_path
        temp_file.try(&.delete)
      end

      private struct QueryRowsResult
        getter rows : Array(Array(String))
        getter error : String?

        def initialize(@rows : Array(Array(String)), @error : String? = nil)
        end
      end

      private def write_program(program : String) : File
        File.tempfile("chiasmus-prolog", ".pl") do |file|
          file.print(program)
          file.puts unless program.ends_with?('\n')
        end
      end

      private def run_findall(module_name : String, query : String, variables : Array(String)) : QueryRowsResult
        goal = clean_goal(query)
        projection = variables.empty? ? "[]" : "[#{variables.join(", ")}]"
        wrapper = "findall(#{projection}, (#{module_name}:(#{goal})), Results)"
        term = parse_term(wrapper)
        return QueryRowsResult.new([] of Array(String), last_exception) unless term
        parsed_term = term

        call_predicate = LibProlog.predicate("call", 1, nil)
        args = LibProlog.new_term_refs(1)
        LibProlog.put_term(args, parsed_term)

        query_id = LibProlog.open_query(
          nil,
          LibProlog::PL_Q_NORMAL | LibProlog::PL_Q_NODEBUG | LibProlog::PL_Q_CATCH_EXCEPTION,
          call_predicate,
          args
        )

        if LibProlog.next_solution(query_id) == 0
          error = exception_message(query_id) || "query failed"
          LibProlog.close_query(query_id)
          return QueryRowsResult.new([] of Array(String), error)
        end

        results = LibProlog.new_term_ref
        unless LibProlog.get_arg(3, parsed_term, results) != 0
          error = exception_message(query_id) || "failed to extract query results"
          LibProlog.close_query(query_id)
          return QueryRowsResult.new([] of Array(String), error)
        end

        rows = parse_result_rows(results)
        LibProlog.close_query(query_id)

        QueryRowsResult.new(rows)
      end

      private def build_answers(rows : Array(Array(String)), variables : Array(String)) : Array(PrologAnswer)
        rows.map do |values|
          bindings = {} of String => String
          variables.each_with_index do |name, index|
            bindings[name] = values[index] if index < values.size
          end

          formatted = if bindings.empty?
                        "true"
                      else
                        variables.compact_map { |name| bindings[name]?.try { |value| "#{name} = #{value}" } }.join(", ")
                      end

          PrologAnswer.new(bindings, formatted)
        end
      end

      private def collect_trace(module_name : String) : Array(String)?
        trace_result = run_findall(module_name, "trace_goal(X)", ["X"])
        return nil if trace_result.error

        seen = Set(String).new
        trace = [] of String

        build_answers(trace_result.rows, ["X"]).each do |answer|
          entry = answer.bindings["X"]?
          next unless entry
          next if seen.includes?(entry)

          seen << entry
          trace << entry
          break if trace.size >= MAX_TRACE_ENTRIES
        end

        trace.empty? ? nil : trace
      end

      private def unload_file(path : String) : Nil
        call_goal("unload_file(#{quote_atom(path)})")
      rescue
      end

      private def call_goal(goal : String) : String?
        term = parse_term(goal)
        return last_exception unless term
        parsed_term = term

        call_predicate = LibProlog.predicate("call", 1, nil)
        args = LibProlog.new_term_refs(1)
        LibProlog.put_term(args, parsed_term)

        query_id = LibProlog.open_query(
          nil,
          LibProlog::PL_Q_NORMAL | LibProlog::PL_Q_NODEBUG | LibProlog::PL_Q_CATCH_EXCEPTION,
          call_predicate,
          args
        )

        success = LibProlog.next_solution(query_id) != 0
        error = exception_message(query_id)
        LibProlog.close_query(query_id)

        return error if error
        success ? nil : "goal failed: #{goal}"
      end

      private def parse_result_rows(results : LibProlog::Term) : Array(Array(String))
        parse_list(results).map do |binding_list|
          parse_list(binding_list).map { |value| term_to_string(value) }
        end
      end

      private def parse_term(source : String) : LibProlog::Term?
        term = LibProlog.new_term_ref
        return term if LibProlog.chars_to_term(source, term) != 0

        nil
      end

      private def parse_list(list_term : LibProlog::Term) : Array(LibProlog::Term)
        items = [] of LibProlog::Term
        current = LibProlog.new_term_ref
        LibProlog.put_term(current, list_term)

        loop do
          break if LibProlog.get_nil(current) != 0

          head = LibProlog.new_term_ref
          tail = LibProlog.new_term_ref
          raise "expected list term" if LibProlog.get_list(current, head, tail) == 0

          item = LibProlog.new_term_ref
          LibProlog.put_term(item, head)
          items << item
          LibProlog.put_term(current, tail)
        end

        items
      end

      private def term_to_string(term : LibProlog::Term) : String
        chars = Pointer(UInt8).null
        flags = LibProlog::CVT_ALL | LibProlog::CVT_WRITEQ | LibProlog::BUF_RING
        raise "failed to stringify term" if LibProlog.get_chars(term, pointerof(chars), flags) == 0

        String.new(chars)
      end

      private def exception_message(query_id : LibProlog::Query) : String?
        exception = LibProlog.exception(query_id)
        return nil if exception.null?

        message = term_to_string(exception)
        LibProlog.clear_exception
        message
      end

      private def last_exception : String
        exception = LibProlog.exception(Pointer(UInt8).null.as(LibProlog::Query))
        return "prolog parse failed" if exception.null?

        message = term_to_string(exception)
        LibProlog.clear_exception
        message
      end

      private def clean_goal(query : String) : String
        query.strip.sub(/\.\s*\z/, "")
      end

      private def next_module_name : String
        "chiasmus_#{@@module_counter.add(1_i64)}"
      end

      private def extract_query_variables(query : String) : Array(String)
        clean_goal(query)
          .scan(/\b[A-Z][A-Za-z0-9_]*\b/)
          .map(&.[0])
          .uniq!
      end

      private def quote_atom(value : String) : String
        "'#{value.gsub("\\", "\\\\").gsub("'", "\\\\'")}'"
      end

      private def instrument_for_tracing(program : String) : String
        output = [":- dynamic(trace_goal/1)."]

        split_clauses(program).each do |clause|
          trimmed = clause.strip
          if trimmed.empty? || trimmed.starts_with?("%") || trimmed.starts_with?(":-")
            output << "#{trimmed}."
            next
          end

          if match = trimmed.match(/^(.+?)\s*:-\s*(.+)\s*$/)
            head = match[1].strip
            body = match[2].strip
            output << "#{head} :- #{body}, assertz(trace_goal(#{head}))."
          else
            output << "#{trimmed} :- assertz(trace_goal(#{trimmed}))."
          end
        end

        output.join("\n")
      end

      private def split_clauses(program : String) : Array(String)
        clauses = [] of String
        current = String::Builder.new
        depth = 0
        in_single_quote = false
        escaped = false

        program.each_char do |char|
          if in_single_quote
            in_single_quote, escaped = handle_quoted_char(current, char, escaped)
            next
          end

          case char
          when '\''
            start_quoted_section(current, char)
            in_single_quote = true
          when '(', '[', '{'
            depth = append_nested_char(current, char, depth, 1)
          when ')', ']', '}'
            depth = append_nested_char(current, char, depth, -1)
          when '.'
            if depth == 0
              flush_clause(clauses, current)
              current = String::Builder.new
            else
              current << char
            end
          else
            current << char
          end
        end

        trailing = current.to_s.strip
        clauses << trailing unless trailing.empty?
        clauses
      end

      private def handle_quoted_char(current : String::Builder, char : Char, escaped : Bool) : {Bool, Bool}
        current << char

        return {true, false} if escaped
        return {true, true} if char == '\\'
        return {false, false} if char == '\''

        {true, false}
      end

      private def start_quoted_section(current : String::Builder, char : Char) : Nil
        current << char
      end

      private def append_nested_char(current : String::Builder, char : Char, depth : Int32, direction : Int32) : Int32
        current << char
        next_depth = depth + direction
        next_depth < 0 ? 0 : next_depth
      end

      private def flush_clause(clauses : Array(String), current : String::Builder) : Nil
        clause = current.to_s.strip
        clauses << clause unless clause.empty?
      end
    end
  end
end
