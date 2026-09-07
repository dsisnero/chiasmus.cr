require "uuid"
require "./types"
require "./z3_solver"
require "./prolog_solver"
require "crolog"

module Chiasmus
  module Solvers
    PROLOG_QUERY_TIMEOUT = 30.seconds

    # Each SolverSession has a unique ID and spawns its own dispatch fiber.
    # PrologRuntime is a shared singleton (SWI-Prolog is not fiber-safe).
    # All Prolog requests are serialised through a single dedicated worker
    # fiber inside PrologRuntime so that every PL_* call originates from the
    # same C-stack context.
    class SolverSession
      getter id : String

      record PrologRequest,
        program : String,
        query : String,
        explain : Bool,
        response : Channel(SolverResult)

      def initialize(@id : String, @solver : Solver)
        @channel = Channel(PrologRequest).new(4)
        @worker_done = nil.as(Channel(Bool)?)
        @disposed = false
      end

      def self.create(type : String) : SolverSession
        id = UUID.random.to_s
        solver = case type.downcase
                 when "z3"     then Z3Solver.new
                 when "prolog" then PrologSolver.new
                 else               raise "Unknown solver type: #{type}"
                 end

        session = SolverSession.new(id, solver)
        session.start_worker if type.downcase == "prolog"
        session
      end

      # Spawn a dispatch fiber for this session.
      # Prolog calls are forwarded to the shared PrologRuntime's own worker
      # fiber, which keeps all PL_* operations on a single C-stack.
      protected def start_worker : Nil
        chan = @channel || raise "Bug: channel not initialized"
        session_id = @id
        done = Channel(Bool).new(1)
        @worker_done = done

        spawn(name: "chiasmus-session-#{session_id}") do
          loop do
            request = chan.receive?
            break unless request
            begin
              result = PrologRuntime.shared.solve(request.program, request.query, request.explain)
              request.response.send(result)
            rescue ex
              request.response.send(ErrorResult.new(ex.message || ex.class.name))
            end
          end
        ensure
          done.send(true)
        end
      end

      def solve(input : SolverInput) : SolverResult
        raise "Session disposed" if @disposed

        case input
        when PrologSolverInput
          solve_prolog(input.program, input.query, input.explain)
        else
          @solver.solve(input)
        end
      end

      def solve_async(input : SolverInput) : Channel(SolverResult)
        response = Channel(SolverResult).new(1)

        if @disposed
          response.send(ErrorResult.new("Session disposed"))
          return response
        end

        case input
        when PrologSolverInput
          solve_prolog_async(input.program, input.query, input.explain, response)
        else
          spawn do
            response.send(@solver.solve(input))
          rescue ex
            response.send(ErrorResult.new(ex.message || ex.class.name))
          end
        end

        response
      end

      private def solve_prolog(program : String, query : String, explain : Bool) : SolverResult
        chan = @channel || raise "Prolog worker not started"
        response = Channel(SolverResult).new(1)
        chan.send(PrologRequest.new(program, query, explain, response))

        select
        when result = response.receive
          result
        when timeout(PROLOG_QUERY_TIMEOUT)
          ErrorResult.new("Prolog query timed out after #{PROLOG_QUERY_TIMEOUT}")
        end
      end

      private def solve_prolog_async(program : String, query : String, explain : Bool, response : Channel(SolverResult)) : Nil
        chan = @channel || raise "Prolog worker not started"
        chan.send(PrologRequest.new(program, query, explain, response))
      rescue ex
        response.send(ErrorResult.new(ex.message || ex.class.name))
      end

      def dispose : Nil
        return if @disposed
        @disposed = true
        @channel.try(&.close)
        @worker_done.try(&.receive)
        @worker_done = nil
        @solver.dispose
      end
    end
  end
end
