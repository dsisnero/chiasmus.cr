module Chiasmus
  module Solvers
    enum SolverType
      Z3
      Prolog
    end

    struct PrologAnswer
      getter bindings : Hash(String, String)
      getter formatted : String

      def initialize(@bindings : Hash(String, String), @formatted : String)
      end
    end

    alias SolverResult = SatResult | UnsatResult | UnknownResult | SuccessResult | ErrorResult

    struct SatResult
      getter model : Hash(String, String)

      def initialize(@model : Hash(String, String))
      end

      def status : String
        "sat"
      end
    end

    struct UnsatResult
      getter unsat_core : Array(String)?

      def initialize(@unsat_core : Array(String)? = nil)
      end

      def status : String
        "unsat"
      end
    end

    struct UnknownResult
      def status : String
        "unknown"
      end
    end

    struct SuccessResult
      getter answers : Array(PrologAnswer)
      getter trace : Array(String)?

      def initialize(@answers : Array(PrologAnswer), @trace : Array(String)? = nil)
      end

      def status : String
        "success"
      end
    end

    struct ErrorResult
      getter error : String

      def initialize(@error : String)
      end

      def status : String
        "error"
      end
    end

    alias SolverInput = Z3SolverInput | PrologSolverInput

    struct Z3SolverInput
      getter type : SolverType
      getter smtlib : String

      def initialize(@smtlib : String, @type : SolverType = SolverType::Z3)
      end
    end

    struct PrologSolverInput
      getter type : SolverType
      getter program : String
      getter query : String
      getter? explain : Bool

      def initialize(@program : String, @query : String, @explain : Bool = false, @type : SolverType = SolverType::Prolog)
      end

      def explain : Bool
        @explain
      end
    end

    struct CorrectionAttempt
      getter input : SolverInput
      getter result : SolverResult?
      getter error : String?

      def initialize(@input : SolverInput, @result : SolverResult?, @error : String?)
      end
    end

    struct CorrectionResult
      getter result : SolverResult
      getter? converged : Bool
      getter rounds : Int32
      getter history : Array(CorrectionAttempt)

      def initialize(@result : SolverResult, @converged : Bool, @rounds : Int32, @history : Array(CorrectionAttempt))
      end

      def converged : Bool
        @converged
      end
    end

    alias SpecFixer = Proc(CorrectionAttempt, String, Int32, SolverResult?, SolverInput?, SolverInput?)

    abstract class Solver
      abstract def type : SolverType
      abstract def solve(input : SolverInput) : SolverResult
      abstract def dispose : Nil
    end
  end
end
