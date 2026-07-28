require "json"
{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
  require "fiber/execution_context"
{% end %}

module Chiasmus
  module Solvers
    class Z3Solver < Solver
      DEFAULT_TIMEOUT = 30.seconds

      record SolverResult, status : String, model : Hash(String, String) = Hash(String, String).new, unsat_core : Array(String) = [] of String, error : String = "", reason : String = "" do
        include JSON::Serializable
      end

      def initialize(@command : String = "z3", @timeout : Time::Span = DEFAULT_TIMEOUT)
      end

      def type : SolverType
        SolverType::Z3
      end

      def solve(input : SolverInput) : Solvers::SolverResult
        case input
        when Z3SolverInput
          result = solve_z3(input.smtlib)
          convert_result(result)
        else
          raise "Z3Solver only supports Z3SolverInput"
        end
      end

      def dispose : Nil
        # The process belongs to the shared runtime, not an individual solver
        # facade. Shutting it down here could cancel another client's request.
      end

      # The synchronous Solver API is retained for compatibility. Callers that
      # can continue work should use this channel-based entry point instead.
      def solve_async(input : Z3SolverInput) : Channel(Solvers::SolverResult)
        response = Channel(Solvers::SolverResult).new(1)

        spawn do
          begin
            response.send(solve(input))
          rescue ex
            response.send(Solvers::ErrorResult.new(ex.message || ex.class.name))
          end
        end

        response
      end

      private def convert_result(result : SolverResult) : Solvers::SolverResult
        case result.status
        when "sat"
          Solvers::SatResult.new(result.model)
        when "unsat"
          Solvers::UnsatResult.new(result.unsat_core)
        when "unknown"
          Solvers::UnknownResult.new
        else
          Solvers::ErrorResult.new(result.error)
        end
      end

      private def solve_z3(smtlib : String) : SolverResult
        sanitized = sanitize_smtlib(smtlib)
        if sanitized.empty?
          return SolverResult.new(status: "sat", model: {} of String => String)
        end

        z3_input = "#{sanitized}\n(check-sat)\n(get-model)\n(get-unsat-core)"
        output = run_z3_persistent(z3_input)
        parse_z3_output(output)
      end

      private def sanitize_smtlib(input : String) : String
        input
          .gsub(/\(\s*check-sat\s*\)/, "")
          .gsub(/\(\s*get-model\s*\)/, "")
          .gsub(/\(\s*get-unsat-core\s*\)/, "")
          .gsub(/\(\s*exit\s*\)/, "")
          .gsub(/\(\s*set-option\s+:produce-unsat-cores\s+\w+\s*\)/, "")
          .strip
      end

      # Run Z3 via persistent process — keeps Z3 alive between calls.
      # The actor owns the process and bounds every request with a deadline.
      private def run_z3_persistent(input : String) : String
        Z3Process.call(@command, input, @timeout)
      end

      private def parse_z3_output(output : String) : SolverResult
        lines = output.lines.map(&.strip).reject(&.empty?)
        return SolverResult.new(status: "error", error: "Empty response from Z3") if lines.empty?

        first_line = lines[0]
        case first_line
        when "sat"
          parse_sat_output(lines)
        when "unsat"
          parse_unsat_output(lines)
        when "unknown"
          SolverResult.new(status: "unknown", reason: lines[1..].join(' '))
        else
          if output.includes?("error")
            SolverResult.new(status: "error", error: output)
          else
            SolverResult.new(status: "error", error: "Unexpected Z3 output: #{output}")
          end
        end
      end

      private def parse_sat_output(lines : Array(String)) : SolverResult
        model = {} of String => String
        current_var = ""
        current_value = ""
        in_define_fun = false

        lines[1..].each do |line|
          if line == "("
            next
          elsif line == ")"
            break
          else
            if line.starts_with?("(define-fun ")
              in_define_fun = true
              if match = line.match(/\(define-fun\s+(\w+)\s+\(\)\s+\w+/)
                current_var = match[1]
                current_value = ""
              end
            elsif in_define_fun && line.ends_with?(")")
              value_part = line[0...-1].strip
              current_value += value_part unless value_part.empty?
              model[current_var] = current_value.strip
              in_define_fun = false
              current_var = ""
              current_value = ""
            elsif in_define_fun
              current_value += line.strip + " "
            end
          end
        end

        SolverResult.new(status: "sat", model: model)
      end

      private def parse_unsat_output(lines : Array(String)) : SolverResult
        unsat_core = [] of String
        lines[1..].each do |line|
          next unless line.starts_with?("(") && line.ends_with?(")")
          next if line.starts_with?("(error ")
          line[1...-1].split.each { |item| unsat_core << item unless item.empty? }
          break
        end
        SolverResult.new(status: "unsat", unsat_core: unsat_core)
      end
    end

    # Single-owner Z3 process runtime. Every interaction with the process is
    # serialized through a request/reply actor, so callers never share pipes or
    # wait while holding a mutex. A timeout terminates the process before the
    # queue advances, preventing a stale response from contaminating the next
    # request.
    module Z3Process
      extend self

      REQUEST_QUEUE_CAPACITY = 32
      DONE_MARKER            = "<<<Z3_DONE>>>"

      record Request,
        command : String,
        smtlib : String,
        timeout : Time::Span,
        response : Channel(String)

      record OutputEvent, line : String? = nil, error : String? = nil, eof : Bool = false

      class ProcessState
        getter command : String
        getter process : Process
        getter input : IO::FileDescriptor
        getter output_events : Channel(OutputEvent)
        getter reader_cancel : Channel(Bool)

        def initialize(
          @command : String,
          @process : Process,
          @input : IO::FileDescriptor,
          @output_events : Channel(OutputEvent),
          @reader_cancel : Channel(Bool),
        )
        end
      end

      class ResponseAccumulator
        def initialize
          @lines = [] of String
          @errors = [] of String
          @started = false
        end

        def consume(event : OutputEvent) : String?
          return "error: #{event.error}" if event.error
          return "error: Z3 closed its output stream" if event.eof

          line = event.line.to_s.strip
          if line == DONE_MARKER
            return complete if @started
            @started = true
          elsif @started && !line.empty?
            append(line)
          end

          nil
        end

        private def append(line : String) : Nil
          if line.starts_with?("(error ") && !Z3Process.expected_query_error?(line)
            @errors << line
          else
            @lines << line
          end
        end

        private def complete : String
          @errors.empty? ? @lines.join("\n") : "error: #{@errors.join("\n")}"
        end
      end

      @@requests : Channel(Request)?
      @@worker_done : Channel(Bool)?
      @@worker_lock = Mutex.new
      {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
        @@worker_context : Fiber::ExecutionContext::Isolated?
      {% end %}

      def call(command : String, smtlib : String, timeout : Time::Span) : String
        call_async(command, smtlib, timeout).receive
      end

      def call_async(command : String, smtlib : String, timeout : Time::Span) : Channel(String)
        response = Channel(String).new(1)
        begin
          request = Request.new(command, smtlib, timeout, response)
          requests = ensure_worker

          select
          when requests.send(request)
          else
            response.send("error: Z3 request queue is full")
          end
        rescue ex
          response.send("error: #{ex.message || ex.class.name}")
        end

        response
      end

      # Test and shutdown hook. Closing the request channel lets the owner
      # terminate its child before the isolated context is joined.
      def reset : Nil
        requests = nil.as(Channel(Request)?)
        done = nil.as(Channel(Bool)?)
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          context = nil.as(Fiber::ExecutionContext::Isolated?)
        {% end %}

        @@worker_lock.synchronize do
          requests = @@requests
          done = @@worker_done
          @@requests = nil
          @@worker_done = nil
          {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
            context = @@worker_context
            @@worker_context = nil
          {% end %}
        end

        requests.try(&.close)
        done.try(&.receive)
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          context.try(&.wait)
        {% end %}
      end

      private def ensure_worker : Channel(Request)
        @@worker_lock.synchronize do
          existing = @@requests
          return existing if existing

          requests = Channel(Request).new(REQUEST_QUEUE_CAPACITY)
          done = Channel(Bool).new(1)
          {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
            context = Fiber::ExecutionContext::Isolated.new("chiasmus-z3-worker") do
              run_worker_loop(requests, done)
            end
            @@worker_context = context
          {% else %}
            spawn(name: "chiasmus-z3-worker") { run_worker_loop(requests, done) }
          {% end %}
          @@requests = requests
          @@worker_done = done
          requests
        end
      end

      private def run_worker_loop(requests : Channel(Request), done : Channel(Bool)) : Nil
        state = nil.as(ProcessState?)
        begin
          while request = requests.receive?
            state = handle_request(request, state)
          end
        ensure
          stop_process(state)
          done.send(true)
        end
      end

      private def handle_request(request : Request, state : ProcessState?) : ProcessState?
        if state && state.command != request.command
          stop_process(state)
          state = nil
        end
        state ||= start_process(request.command)

        output = run_request(state, request)
        if output.starts_with?("error:")
          stop_process(state)
          request.response.send(output)
          return nil
        end
        request.response.send(output)
        state
      rescue ex
        request.response.send("error: #{ex.message || ex.class.name}")
        stop_process(state)
        nil
      end

      private def run_request(state : ProcessState, request : Request) : String
        state.input.puts("(echo \"#{DONE_MARKER}\")")
        state.input.puts(request.smtlib)
        state.input.puts("(echo \"#{DONE_MARKER}\")")
        state.input.puts("(reset)")
        state.input.flush

        deadline = Channel(Bool).new(1)
        spawn { sleep request.timeout; deadline.send(true) }

        response = ResponseAccumulator.new
        loop do
          select
          when event = state.output_events.receive?
            return "error: Z3 closed its output stream" unless event
            completed = response.consume(event)
            return completed if completed
          when deadline.receive
            stop_process(state)
            return "error: Z3 timed out after #{request.timeout}"
          end
        end
      end

      def expected_query_error?(line : String) : Bool
        line.includes?("model is not available") || line.includes?("unsat core is not available")
      end

      private def start_process(command : String) : ProcessState
        process = Process.new(command, ["-smt2", "-in"],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe)
        input = process.input.as(IO::FileDescriptor)
        output = process.output.as(IO::FileDescriptor)
        error = process.error.as(IO::FileDescriptor)
        events = Channel(OutputEvent).new(64)
        cancel = Channel(Bool).new

        start_stdout_reader(output, events, cancel)
        start_stderr_drain(error, cancel)

        input.puts("(set-option :produce-unsat-cores true)")
        input.flush
        ProcessState.new(command, process, input, events, cancel)
      end

      private def start_stdout_reader(output : IO::FileDescriptor, events : Channel(OutputEvent), cancel : Channel(Bool)) : Nil
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          Fiber::ExecutionContext.default.spawn { drain_stdout(output, events, cancel) }
        {% else %}
          spawn { drain_stdout(output, events, cancel) }
        {% end %}
      end

      private def drain_stdout(output : IO::FileDescriptor, events : Channel(OutputEvent), cancel : Channel(Bool)) : Nil
        while line = output.gets
          select
          when events.send(OutputEvent.new(line: line))
          when cancel.receive?
            break
          end
        end
        select
        when events.send(OutputEvent.new(eof: true))
        when cancel.receive?
        end
      rescue ex
        select
        when events.send(OutputEvent.new(error: ex.message || ex.class.name))
        when cancel.receive?
        end
      end

      # stderr must be drained independently or a verbose failing solver can
      # fill its pipe and block before stdout reaches the completion marker.
      private def start_stderr_drain(error : IO::FileDescriptor, cancel : Channel(Bool)) : Nil
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
          Fiber::ExecutionContext.default.spawn { drain_stderr(error, cancel) }
        {% else %}
          spawn { drain_stderr(error, cancel) }
        {% end %}
      end

      private def drain_stderr(error : IO::FileDescriptor, cancel : Channel(Bool)) : Nil
        while error.gets
          select
          when cancel.receive?
            break
          else
            # Reading is the work: discard stderr after preventing pipe backpressure.
          end
        end
      rescue
      end

      private def stop_process(state : ProcessState?) : Nil
        return unless state

        state.reader_cancel.close
        state.input.close rescue nil
        state.process.terminate rescue nil
        state.process.wait rescue nil
      end
    end
  end
end
