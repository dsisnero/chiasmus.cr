require "./types"
require "./session"
require "crolog"
require "tracing"
{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
  require "fiber/execution_context"
{% end %}

module Chiasmus
  module Solvers
    class PrologSolver < Solver
      MAX_ANSWERS       =    1000
      MAX_INFERENCES    = 100_000
      MAX_TRACE_ENTRIES =     500

      @session : SolverSession?

      private def ensure_session : SolverSession
        @session ||= begin
          PrologRuntime.acquire
          SolverSession.create("prolog")
        rescue ex
          PrologRuntime.release
          raise ex
        end
      end

      def type : SolverType
        SolverType::Prolog
      end

      def solve(input : SolverInput) : SolverResult
        return ErrorResult.new("Expected prolog input type") unless input.is_a?(PrologSolverInput)

        solve(input.program, input.query, input.explain)
      end

      def solve(program : String, query : String, explain : Bool = false) : SolverResult
        Tracing.info(
          "chiasmus.prolog.solve.enqueue",
          program_bytes: program.bytesize,
          query_bytes: query.bytesize,
          explain: explain
        )
        result = ensure_session.solve(PrologSolverInput.new(program: program, query: query, explain: explain))
        Tracing.info(
          "chiasmus.prolog.solve.complete",
          status: result.status,
          explain: explain
        )
        result
      end

      def solve_async(program : String, query : String, explain : Bool = false) : Channel(SolverResult)
        ensure_session.solve_async(PrologSolverInput.new(program: program, query: query, explain: explain))
      end

      def dispose : Nil
        session = @session
        return unless session

        session.dispose
        @session = nil
        PrologRuntime.release
      end
    end

    class PrologRuntime
      MAX_ANSWERS          = PrologSolver::MAX_ANSWERS
      MAX_INFERENCES       = PrologSolver::MAX_INFERENCES
      MAX_TRACE_ENTRIES    = PrologSolver::MAX_TRACE_ENTRIES
      GOAL_TIMEOUT_SECONDS = 30

      @@module_counter = Atomic(Int64).new(0_i64)
      @@shared : PrologRuntime?
      @@shared_lock = Mutex.new
      @@active_clients = 0
      @@active_clients_lock = Mutex.new

      # All PL_* calls must originate from one stable execution thread or
      # SWI-Prolog raises stack_avail___LD assertions. On Crystal 1.21+ the
      # scheduler may resume a normal fiber on another thread, so we run the
      # shared worker loop inside an isolated execution context.
      record SolveRequest,
        program : String,
        query : String,
        explain : Bool,
        response : Channel(SolverResult)

      @@worker_channel : Channel(SolveRequest)?
      @@worker_done : Channel(Bool)?
      {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
        @@worker_context : Fiber::ExecutionContext::Isolated?
      {% end %}
      @@worker_channel_lock = Mutex.new

      def self.acquire : Nil
        @@active_clients_lock.synchronize do
          @@active_clients += 1
        end

        Tracing.info("chiasmus.prolog.runtime.acquire", active_clients: @@active_clients)
        shared
      end

      def self.release : Nil
        active_clients = @@active_clients_lock.synchronize do
          if @@active_clients > 0
            @@active_clients -= 1
          end
          @@active_clients
        end

        Tracing.info("chiasmus.prolog.runtime.release", active_clients: active_clients)
      end

      # Thread-safe shared PrologRuntime singleton.
      def self.shared : PrologRuntime
        @@shared_lock.synchronize do
          @@shared ||= new
        end
      end

      # Reset the shared instance (for tests).
      def self.reset_shared : Nil
        @@active_clients_lock.synchronize { @@active_clients = 0 }
        shutdown
      end

      def self.shutdown : Nil
        Tracing.info("chiasmus.prolog.runtime.shutdown")
        chan = nil.as(Channel(SolveRequest)?)
        done = nil.as(Channel(Bool)?)
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          context = nil.as(Fiber::ExecutionContext::Isolated?)
        {% end %}
        @@worker_channel_lock.synchronize do
          channel = @@worker_channel
          worker_done = @@worker_done
          @@worker_channel = nil
          @@worker_done = nil
          chan = channel
          done = worker_done
          {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
            context = @@worker_context
            @@worker_context = nil
          {% end %}
        end
        chan.try(&.close)
        done.try(&.receive)
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          context.try(&.wait)
        {% end %}

        @@shared_lock.synchronize { @@shared = nil }
      end

      def initialize
        ensure_worker
      end

      # Start the shared worker loop if not already running.
      private def ensure_worker : Nil
        @@worker_channel_lock.synchronize do
          return unless @@worker_channel.nil?

          chan = Channel(SolveRequest).new(32)
          done = Channel(Bool).new(1)
          startup = Channel(Exception?).new(1)
          {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
            context = Fiber::ExecutionContext::Isolated.new("chiasmus-prolog-worker") do
              run_worker_loop(chan, startup, done)
            end
          {% else %}
            context = nil
            spawn(name: "chiasmus-prolog-worker") do
              run_worker_loop(chan, startup, done)
            end
          {% end %}

          if ex = startup.receive
            {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
              context.wait
            {% end %}
            raise ex
          end

          @@worker_channel = chan
          @@worker_done = done
          {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
            @@worker_context = context
          {% end %}
        end
      end

      private def run_worker_loop(
        chan : Channel(SolveRequest),
        startup : Channel(Exception?),
        done : Channel(Bool),
      ) : Nil
        begin
          # Initialize SWI-Prolog on this worker context's owned thread.
          Crolog.init_with_argv("chiasmus", "--quiet")
          startup.send(nil)

          loop do
            request = chan.receive?
            break unless request

            begin
              result = solve_sync(request.program, request.query, request.explain)
              request.response.send(result)
            rescue ex
              request.response.send(ErrorResult.new(ex.message || ex.class.name))
            end
          end
        rescue ex
          startup.send(ex)
        ensure
          done.send(true)
        end
      end

      def solve(program : String, query : String, explain : Bool) : SolverResult
        chan = @@worker_channel
        raise "PrologRuntime worker not started" unless chan

        response = Channel(SolverResult).new(1)
        chan.send(SolveRequest.new(program, query, explain, response))
        response.receive
      end

      private def solve_sync(program : String, query : String, explain : Bool) : SolverResult
        Tracing.info("chiasmus.prolog.solve_sync.start", explain: explain)
        source = explain ? instrument_for_tracing(program) : program
        temp_file = write_program(source)
        temp_path = temp_file.path
        module_name = next_module_name

        consult_result = call_goal("load_files(#{quote_atom(temp_path)}, [module(#{module_name}), silent(true)])")
        return ErrorResult.new(consult_result) if consult_result
        Tracing.info("chiasmus.prolog.solve_sync.consulted", explain: explain)

        variables = extract_query_variables(query)
        results = run_findall(module_name, query, variables)
        if error = results.error
          return ErrorResult.new(error)
        end

        answers = build_answers(results.rows, variables)
        Tracing.info(
          "chiasmus.prolog.solve_sync.answers",
          explain: explain,
          answer_count: answers.size
        )
        trace = explain ? collect_trace(module_name) : nil
        Tracing.info(
          "chiasmus.prolog.solve_sync.trace",
          explain: explain,
          trace_entries: trace.try(&.size) || 0
        )
        SuccessResult.new(answers, trace)
      ensure
        if temp_path
          unload_file(temp_path)
          File.delete(temp_path) if File.exists?(temp_path)
        end
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
        wrapper = "call_with_time_limit(#{GOAL_TIMEOUT_SECONDS}, findall(#{projection}, (#{module_name}:(#{goal})), Results))"
        Tracing.info(
          "chiasmus.prolog.run_findall.start",
          goal_bytes: goal.bytesize,
          variable_count: variables.size
        )
        term = parse_term(wrapper)
        return QueryRowsResult.new([] of Array(String), last_exception) unless term
        parsed_term = term
        Tracing.info("chiasmus.prolog.run_findall.parsed")

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
        Tracing.info("chiasmus.prolog.run_findall.solved")

        inner = LibProlog.new_term_ref
        unless LibProlog.get_arg(2, parsed_term, inner) != 0
          error = exception_message(query_id) || "failed to extract timed query"
          LibProlog.close_query(query_id)
          return QueryRowsResult.new([] of Array(String), error)
        end

        results = LibProlog.new_term_ref
        unless LibProlog.get_arg(3, inner, results) != 0
          error = exception_message(query_id) || "failed to extract query results"
          LibProlog.close_query(query_id)
          return QueryRowsResult.new([] of Array(String), error)
        end

        rows = parse_result_rows(results)
        LibProlog.close_query(query_id)
        Tracing.info("chiasmus.prolog.run_findall.complete", row_count: rows.size)

        QueryRowsResult.new(rows)
      end

      private def build_answers(rows : Array(Array(String)), variables : Array(String)) : Array(PrologAnswer)
        rows.first(MAX_ANSWERS).map do |values|
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
        timed_goal = "call_with_time_limit(#{GOAL_TIMEOUT_SECONDS}, (#{goal}))"
        Tracing.info("chiasmus.prolog.call_goal.start", goal_bytes: goal.bytesize)
        term = parse_term(timed_goal)
        return last_exception unless term
        parsed_term = term
        Tracing.info("chiasmus.prolog.call_goal.parsed")

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
        Tracing.info("chiasmus.prolog.call_goal.complete", success: success, has_error: !error.nil?)

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

    # --- Shared Prolog utilities (ported from upstream prolog-solver.ts) ---

    class CapReachedError < Exception
    end

    class LimitExceededError < Exception
    end

    module PrologUtils
      extend self

      def normalize_query(q : String) : String
        s = q.strip
        s = s[2..].strip if s.starts_with?("?-")
        s = s.rchop(".").strip if s.ends_with?(".")
        s
      end

      def format_bindings(bindings : Hash(String, String)) : String
        return "true" if bindings.empty?
        bindings.map { |k, v| "#{k} = #{v}" }.join(", ")
      end

      # Render a JSON-like value to Prolog term syntax.
      def term_to_prolog_string(value : JSON::Any) : String
        case value.raw
        when Nil   then "_"
        when Bool  then value.raw.to_s
        when Int64 then value.as_i.to_s
        when Float64
          v = value.as_f
          v == v.to_i ? v.to_i.to_s : v.to_s
        when String
          s = value.as_s
          if s =~ /^[a-z][a-zA-Z0-9_]*$/
            s
          else
            "'#{s.gsub("\\", "\\\\").gsub("'", "\\'")}'"
          end
        when Array
          arr = value.as_a
          "[" + arr.map { |e| term_to_prolog_string(e) }.join(", ") + "]"
        when Hash
          h = value.as_h
          if h.has_key?("functor")
            fn = h["functor"].as_s
            args = h["args"]?.try(&.as_a) || [] of JSON::Any
            "#{fn}(#{args.map { |a| term_to_prolog_string(a) }.join(", ")})"
          else
            value.to_json
          end
        else
          value.to_json
        end
      end
    end
  end
end
