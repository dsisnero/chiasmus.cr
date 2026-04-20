require "json"

# require "prolog_cr"  # This shard is not available in the current build.
# require "prolog_parser"

module Chiasmus
  module Solvers
    # Crystal-native Prolog solver using the prolog_cr library.
    # This remains unavailable until that shard is added back.
    class PrologCrSolver
      record SolverResult, status : String, answers : Array(Hash(String, String)) = [] of Hash(String, String), error : String = "", trace : Array(String) = [] of String do
        include JSON::Serializable
      end

      def initialize
      end

      def solve(program : String, query : String, explain : Bool = false) : SolverResult
        # Implementation is deferred until the shard becomes available again.
        SolverResult.new(
          status: "error",
          error: "PrologCr solver not available: prolog_cr shard is missing"
        )
      end
    end
  end
end
