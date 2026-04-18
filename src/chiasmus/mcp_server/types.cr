# MCP server response types
require "json"

module Chiasmus
  module MCPServer
    module Types
      # Base response structure
      abstract struct Response
        include JSON::Serializable

        getter status : String

        def initialize(@status : String)
        end
      end

      struct SuccessResponse < Response
        def initialize
          super("success")
        end
      end

      struct ErrorResponse < Response
        getter error : String

        def initialize(@error : String)
          super("error")
        end
      end

      # Formalize tool response
      struct FormalizeResponse < Response
        getter template : String
        getter solver : String
        getter domain : String
        getter instructions : String
        getter suggestions : Array(String)

        def initialize(@template : String, @solver : String, @domain : String,
                       @instructions : String, @suggestions : Array(String) = [] of String)
          super("success")
        end
      end

      # Solve tool response
      struct SolveResponse < Response
        getter result : SolverResultJSON
        getter converged : Bool
        getter rounds : Int32
        getter template_used : String?
        getter answers : Array(PrologAnswerJSON)
        getter history : Array(CorrectionAttemptJSON)
        getter fallback : Bool = false
        getter message : String? = nil

        def initialize(@result : SolverResultJSON, @converged : Bool, @rounds : Int32,
                       @template_used : String? = nil, @answers : Array(PrologAnswerJSON) = [] of PrologAnswerJSON,
                       @history : Array(CorrectionAttemptJSON) = [] of CorrectionAttemptJSON,
                       @fallback : Bool = false, @message : String? = nil)
          super("success")
        end
      end

      # Skills tool response
      struct SkillsResponse < Response
        getter templates : Array(TemplateJSON)
        getter suggestions : Array(String)? = nil

        def initialize(@templates : Array(TemplateJSON), @suggestions : Array(String)? = nil)
          super("success")
        end
      end

      # JSON representations for serialization
      struct SolverResultJSON
        include JSON::Serializable

        getter status : String
        getter model : Hash(String, String)? = nil
        getter unsat_core : Array(String)? = nil
        getter answers : Array(PrologAnswerJSON)? = nil
        getter trace : Array(String)? = nil
        getter error : String? = nil

        def initialize(@status : String, @model : Hash(String, String)? = nil,
                       @unsat_core : Array(String)? = nil, @answers : Array(PrologAnswerJSON)? = nil,
                       @trace : Array(String)? = nil, @error : String? = nil)
        end
      end

      struct PrologAnswerJSON
        include JSON::Serializable

        getter bindings : Hash(String, String)
        getter formatted : String

        def initialize(@bindings : Hash(String, String), @formatted : String)
        end
      end

      struct CorrectionAttemptJSON
        include JSON::Serializable

        getter input : SolverInputJSON
        getter result : SolverResultJSON?
        getter error : String?

        def initialize(@input : SolverInputJSON, @result : SolverResultJSON? = nil, @error : String? = nil)
        end
      end

      struct SolverInputJSON
        include JSON::Serializable

        getter type : String
        getter smtlib : String? = nil
        getter program : String? = nil
        getter query : String? = nil
        getter explain : Bool? = nil

        def initialize(@type : String, @smtlib : String? = nil, @program : String? = nil,
                       @query : String? = nil, @explain : Bool? = nil)
        end
      end

      struct TemplateJSON
        include JSON::Serializable

        getter name : String
        getter domain : String
        getter solver : String
        getter signature : String
        getter skeleton : String
        getter slots : Array(SlotJSON)
        getter normalizations : Array(NormalizationJSON)
        getter tips : Array(String)
        getter example : String

        def initialize(@name : String, @domain : String, @solver : String, @signature : String,
                       @skeleton : String, @slots : Array(SlotJSON), @normalizations : Array(NormalizationJSON),
                       @tips : Array(String) = [] of String, @example : String = "")
        end
      end

      struct SlotJSON
        include JSON::Serializable

        getter name : String
        getter description : String
        getter format : String

        def initialize(@name : String, @description : String, @format : String)
        end
      end

      struct NormalizationJSON
        include JSON::Serializable

        getter source : String
        getter transform : String

        def initialize(@source : String, @transform : String)
        end
      end

      struct SkillSearchResultJSON
        include JSON::Serializable

        getter template : TemplateJSON
        getter metadata : SkillMetadataJSON
        getter score : Float64

        def initialize(@template : TemplateJSON, @metadata : SkillMetadataJSON, @score : Float64)
        end
      end

      struct SkillMetadataJSON
        include JSON::Serializable

        getter reuse_count : Int32
        getter success_count : Int32
        getter last_used : String?
        getter promoted : Bool

        def initialize(@reuse_count : Int32, @success_count : Int32, @last_used : String? = nil, @promoted : Bool = false)
        end
      end

      # Helper methods to convert from domain objects to JSON types
      def self.solver_result_to_json(result : Solvers::SolverResult) : SolverResultJSON
        case result
        when Solvers::SatResult
          SolverResultJSON.new(
            status: "sat",
            model: result.model
          )
        when Solvers::UnsatResult
          SolverResultJSON.new(
            status: "unsat",
            unsat_core: result.unsat_core
          )
        when Solvers::SuccessResult
          SolverResultJSON.new(
            status: "success",
            answers: result.answers.map { |a| PrologAnswerJSON.new(a.bindings, a.formatted) },
            trace: result.trace
          )
        when Solvers::ErrorResult
          SolverResultJSON.new(
            status: "error",
            error: result.error
          )
        when Solvers::UnknownResult
          SolverResultJSON.new(
            status: "unknown"
          )
        else
          SolverResultJSON.new(
            status: "error",
            error: "Unknown result type"
          )
        end
      end

      def self.solver_input_to_json(input : Solvers::SolverInput) : SolverInputJSON
        case input
        when Solvers::Z3SolverInput
          SolverInputJSON.new(
            type: "z3",
            smtlib: input.smtlib
          )
        when Solvers::PrologSolverInput
          SolverInputJSON.new(
            type: "prolog",
            program: input.program,
            query: input.query,
            explain: input.explain
          )
        else
          SolverInputJSON.new(
            type: "unknown"
          )
        end
      end

      def self.template_to_json(template : Skills::SkillTemplate) : TemplateJSON
        TemplateJSON.new(
          name: template.name,
          domain: template.domain,
          solver: template.solver.to_s.downcase,
          signature: template.signature,
          skeleton: template.skeleton,
          slots: template.slots.map { |s| SlotJSON.new(s.name, s.description, s.format) },
          normalizations: template.normalizations.map { |n| NormalizationJSON.new(n.source, n.transform) },
          tips: template.tips || [] of String,
          example: template.example || ""
        )
      end

      def self.skill_search_result_to_json(result : Skills::SkillSearchResult) : SkillSearchResultJSON
        SkillSearchResultJSON.new(
          template: template_to_json(result.template),
          metadata: SkillMetadataJSON.new(
            reuse_count: result.metadata.reuse_count,
            success_count: result.metadata.success_count,
            last_used: result.metadata.last_used.try(&.to_s),
            promoted: result.metadata.promoted
          ),
          score: result.score
        )
      end
    end
  end
end
