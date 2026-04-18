require "json"

# require "prolog_cr"  # TODO: This shard is not available
# require "prolog_parser"

module Chiasmus
  module Solvers
    # Crystal-native Prolog solver using the prolog_cr library
    # TODO: This solver is not functional until prolog_cr shard is available
    class PrologCrSolver
      record SolverResult, status : String, answers : Array(Hash(String, String)) = [] of Hash(String, String), error : String = "", trace : Array(String) = [] of String do
        include JSON::Serializable
      end

      def initialize
      end

      def solve(program : String, query : String, explain : Bool = false) : SolverResult
        # TODO: Implement when prolog_cr shard is available
        SolverResult.new(
          status: "error",
          error: "PrologCr solver not available: prolog_cr shard is missing"
        )
      end
    end
  end
end
