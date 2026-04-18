require "./types"
require "crolog"

module Chiasmus
  module Solvers
    class Session
      record PrologRequest, program : String, query : String, explain : Bool, response : Channel(SolverResult)

      @@instance : Session?
      @@instance_lock = Mutex.new

      def self.instance : Session
        @@instance_lock.synchronize do
          @@instance ||= new
        end
      end

      @prolog_requests = Channel(PrologRequest).new(64)

      private def initialize
        spawn(name: "chiasmus-prolog-worker") do
          runtime = PrologRuntime.new
          loop do
            request = nil.as(PrologRequest?)
            begin
              request = @prolog_requests.receive
              result = runtime.solve(request.program, request.query, request.explain)
              request.response.send(result)
            rescue ex
              request.try(&.response.send(ErrorResult.new(ex.message || ex.class.name)))
            end
          rescue ex
          end
        end
      end

      def solve_prolog_async(program : String, query : String, explain : Bool = false) : Channel(SolverResult)
        response = Channel(SolverResult).new(1)
        @prolog_requests.send(PrologRequest.new(program, query, explain, response))
        response
      end

      def solve_prolog(program : String, query : String, explain : Bool = false) : SolverResult
        solve_prolog_async(program, query, explain).receive
      end
    end
  end
end
