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
        getter suggestions : Array(JSON::Any)

        def initialize(@template : String, @solver : String, @domain : String,
                       @instructions : String, @suggestions : Array(JSON::Any) = [] of JSON::Any)
          super("success")
        end
      end

      # Solve tool response
      struct SolveResponse < Response
        getter result : SolverResultJSON
        getter? converged : Bool
        getter rounds : Int32

        @[JSON::Field(key: "templateUsed")]
        getter template_used : String?
        getter answers : Array(PrologAnswerJSON)
        getter history : Array(SolveHistoryEntryJSON)
        getter? fallback : Bool = false
        getter message : String? = nil

        def initialize(@result : SolverResultJSON, @converged : Bool, @rounds : Int32,
                       @template_used : String? = nil, @answers : Array(PrologAnswerJSON) = [] of PrologAnswerJSON,
                       @history : Array(SolveHistoryEntryJSON) = [] of SolveHistoryEntryJSON,
                       @fallback : Bool = false, @message : String? = nil)
          super("success")
        end

        def converged : Bool
          @converged
        end

        def fallback : Bool
          @fallback
        end
      end

      # No-LLM solve fallback: return the selected template for user completion.
      struct SolveFallbackResponse < Response
        getter? fallback : Bool
        getter message : String
        getter template : String
        getter solver : String
        getter instructions : String

        def initialize(@message : String, @template : String, @solver : String, @instructions : String, @fallback : Bool = true)
          super("success")
        end

        def fallback : Bool
          @fallback
        end
      end

      # Skills tool response
      struct SkillsResponse < Response
        getter templates : Array(TemplateJSON)
        getter suggestions : Array(JSON::Any)? = nil
        getter collection : Array(SkillWithMetadataJSON)? = nil
        getter search_results : Array(SkillSearchResultJSON)? = nil

        def initialize(
          @templates : Array(TemplateJSON),
          @suggestions : Array(JSON::Any)? = nil,
          @collection : Array(SkillWithMetadataJSON)? = nil,
          @search_results : Array(SkillSearchResultJSON)? = nil,
        )
          super("success")
        end

        # The upstream MCP API uses arrays for query/list results. Keep typed
        # fields for direct Crystal callers while serializing the public shape.
        def to_json(json : JSON::Builder)
          if search_results = @search_results
            search_results.to_json(json)
          elsif collection = @collection
            collection.to_json(json)
          else
            json.array { }
          end
        end
      end

      # Exact template lookup response for chiasmus_skills.
      struct SkillLookupResponse < Response
        getter template : TemplateJSON
        getter metadata : SkillMetadataJSON
        getter related : Array(JSON::Any)

        def initialize(@template : TemplateJSON, @metadata : SkillMetadataJSON, @related : Array(JSON::Any))
          super("success")
        end
      end

      # JSON representations for serialization
      struct SolverResultJSON
        include JSON::Serializable

        getter status : String
        getter model : Hash(String, String)? = nil

        @[JSON::Field(key: "unsatCore")]
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

      struct SolveHistoryEntryJSON
        getter round : Int32
        getter status : String
        getter error : String?

        def initialize(@round : Int32, @status : String, @error : String? = nil)
        end

        # The upstream MCP payload omits error unless this correction attempt
        # actually failed; retaining that distinction avoids null wire fields.
        def to_json(json : JSON::Builder)
          json.object do
            json.field "round", @round
            json.field "status", @status
            json.field "error", @error if @status == "error" && @error
          end
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

      struct SkillWithMetadataJSON
        include JSON::Serializable

        getter template : TemplateJSON
        getter metadata : SkillMetadataJSON

        def initialize(@template : TemplateJSON, @metadata : SkillMetadataJSON)
        end
      end

      struct SkillMetadataJSON
        include JSON::Serializable

        @[JSON::Field(key: "reuseCount")]
        getter reuse_count : Int32

        @[JSON::Field(key: "successCount")]
        getter success_count : Int32

        @[JSON::Field(key: "lastUsed")]
        getter last_used : String?
        getter? promoted : Bool

        def initialize(@reuse_count : Int32, @success_count : Int32, @last_used : String? = nil, @promoted : Bool = false)
        end

        def promoted : Bool
          @promoted
        end
      end

      # Verify tool response
      struct VerifyResponse < Response
        getter result : SolverResultJSON?
        getter results : Array(SolverResultJSON)?

        def initialize(@result : SolverResultJSON? = nil, @results : Array(SolverResultJSON)? = nil)
          super("success")
        end

        def self.error(error_message : String) : ErrorResponse
          ErrorResponse.new(error_message)
        end

        def to_json(json : JSON::Builder)
          if results = @results
            results.to_json(json)
          else
            json.object do
              json.field "status", @status
              json.field "result", @result if @result
            end
          end
        end
      end

      # Lint tool response
      struct LintResponse < Response
        getter spec : String
        getter fixes : Array(String)
        getter errors : Array(String)

        def initialize(@spec : String, @fixes : Array(String) = [] of String, @errors : Array(String) = [] of String)
          super("success")
        end
      end

      # Graph tool response
      struct GraphResponse < Response
        getter analysis : String
        getter result : JSON::Any
        getter warnings : Array(String)

        def initialize(@analysis : String, @result : JSON::Any, @warnings : Array(String) = [] of String)
          super("success")
        end

        def to_json(json : JSON::Builder)
          json.object do
            json.field "status", status
            json.field "analysis", analysis
            json.field "result" do
              result.to_json(json)
            end
            unless warnings.empty?
              json.field "warnings" do
                warnings.to_json(json)
              end
            end
          end
        end
      end

      struct SnapshotStatusResponse < Response
        getter snapshot : String
        getter state : String
        getter updated_at : Int64
        getter error : String? = nil

        def initialize(@snapshot : String, @state : String, @updated_at : Int64, @error : String? = nil)
          super("success")
        end
      end

      # Map tool response
      struct MapResponse < Response
        getter content : String

        def initialize(@content : String)
          super("success")
        end
      end

      struct MapJSONResponse < Response
        getter payload : JSON::Any
        getter warnings : Array(String)

        def initialize(@payload : JSON::Any, @warnings = [] of String)
          super("success")
        end

        def to_json(json : JSON::Builder)
          json.object do
            json.field "status", @status
            @payload.as_h.each { |key, value| json.field key, value }
            json.field "warnings", @warnings unless @warnings.empty?
          end
        end
      end

      struct MapErrorResponse < Response
        getter error : String
        getter warnings : Array(String)

        def initialize(@error : String, @warnings : Array(String))
          super("error")
        end
      end

      # Search tool response
      struct SearchHitJSON
        include JSON::Serializable

        getter name : String
        getter file : String
        getter line : Int32
        getter line_end : Int32?
        getter score : Float64

        def initialize(@name : String, @file : String, @line : Int32, @score : Float64, @line_end : Int32? = nil)
        end
      end

      struct SearchResponse < Response
        getter hits : Array(SearchHitJSON)
        getter warnings : Array(String)?

        def initialize(@hits : Array(SearchHitJSON), @warnings : Array(String)? = nil)
          super("success")
        end
      end

      struct SearchErrorResponse < Response
        getter error : String
        getter warnings : Array(String)

        def initialize(@error : String, @warnings : Array(String) = [] of String)
          super("error")
        end
      end

      struct ReadSymbolResponse < Response
        getter name : String
        getter qualified_name : String?
        getter file : String
        getter kind : String
        getter signature : String?
        getter start_line : Int32
        getter end_line : Int32
        getter content : String

        def initialize(@name : String, @qualified_name : String?, @file : String, @kind : String,
                       @signature : String?, @start_line : Int32, @end_line : Int32, @content : String)
          super("success")
        end
      end

      # Craft tool response
      struct CraftResponse < Response
        # ameba:disable Naming/QueryBoolMethods
        getter created : Bool
        getter template : String?
        getter domain : String?
        getter solver : String?
        getter slots : Int32?
        # ameba:disable Naming/QueryBoolMethods
        getter tested : Bool

        @[JSON::Field(key: "testResult")]
        getter test_result : String?
        getter errors : Array(String)

        def initialize(@created : Bool, @template : String? = nil, @domain : String? = nil,
                       @solver : String? = nil, @slots : Int32? = nil, @tested : Bool = false,
                       @test_result : String? = nil, @errors : Array(String) = [] of String)
          super("success")
        end
      end

      # Review tool response types
      struct ReviewActionJSON
        include JSON::Serializable

        getter tool : String
        getter args : Hash(String, JSON::Any)
        getter interpret : String

        def initialize(@tool : String, @args : Hash(String, JSON::Any), @interpret : String)
        end
      end

      struct ReviewPhaseJSON
        include JSON::Serializable

        getter phase : String
        getter goal : String
        getter actions : Array(ReviewActionJSON)

        def initialize(@phase : String, @goal : String, @actions : Array(ReviewActionJSON))
        end
      end

      struct SuggestedTemplateJSON
        include JSON::Serializable

        getter template : String
        getter when : String
        getter workflow : String

        def initialize(@template : String, @when : String, @workflow : String)
        end
      end

      struct ReviewReportingJSON
        include JSON::Serializable

        getter format : String

        @[JSON::Field(key: "severityLevels")]
        getter severity_levels : Array(String)
        getter instructions : String

        def initialize(@format : String, @severity_levels : Array(String), @instructions : String)
        end
      end

      struct ReviewResponse < Response
        getter files : Array(String)
        getter focus : String
        getter summary : String
        getter phases : Array(ReviewPhaseJSON)

        @[JSON::Field(key: "suggestedTemplates")]
        getter suggested_templates : Array(SuggestedTemplateJSON)
        getter reporting : ReviewReportingJSON

        def initialize(@files : Array(String), @focus : String, @summary : String,
                       @phases : Array(ReviewPhaseJSON), @suggested_templates : Array(SuggestedTemplateJSON),
                       @reporting : ReviewReportingJSON)
          super("success")
        end
      end

      # Learn tool response
      struct LearnResponse < Response
        getter? extracted : Bool
        getter template : String?
        getter domain : String?
        getter solver : String?
        getter signature : String?
        getter slots : Int32?
        getter? promoted : Bool?
        getter reason : String?

        def initialize(@extracted : Bool, @template : String? = nil, @domain : String? = nil,
                       @solver : String? = nil, @signature : String? = nil, @slots : Int32? = nil,
                       @promoted : Bool? = nil, @reason : String? = nil)
          super("success")
        end

        def extracted : Bool
          @extracted
        end

        def promoted : Bool?
          @promoted
        end
      end

      # Crig tool response
      struct CrigResponse < Response
        getter output : String?
        getter model : String?

        def initialize(@output : String? = nil, @model : String? = nil)
          super("success")
        end
      end

      # ────────────────────────────────────────────
      # Tool input structs (JSON::Serializable)
      # ────────────────────────────────────────────

      struct VerifyInput
        include JSON::Serializable

        getter solver : String
        getter input : String?
        getter spec : String?
        getter query : String?
        getter queries : Array(String)?
        # ameba:disable Naming/QueryBoolMethods
        getter explain : Bool = false
        getter format : String = "raw"
      end

      struct SkillsInput
        include JSON::Serializable

        getter name : String?
        getter query : String?
        getter domain : String?
        getter solver : String?
        getter limit : Int32 = 10
      end

      struct FormalizeInput
        include JSON::Serializable

        getter problem : String
      end

      struct SolveInput
        include JSON::Serializable

        getter problem : String
      end

      struct LearnInput
        include JSON::Serializable

        getter solver : String
        getter spec : String
        getter problem : String
      end

      struct LintInput
        include JSON::Serializable

        getter solver : String
        getter input : String
      end

      struct GraphCacheOptions
        include JSON::Serializable

        getter cache_dir : String?
        getter repo_key : String?
        getter max_bytes_per_repo : Int32?
      end

      struct GraphInput
        include JSON::Serializable

        getter files : Array(String)
        getter analysis : String
        getter target : String?
        getter from : String?
        getter to : String?
        getter entry_points : Array(String)?
        # `true` is the upstream opt-in for persistent graph extraction. An
        # object remains a Crystal extension for callers that need an explicit
        # cache directory, repository key, or size limit.
        getter cache : Bool | GraphCacheOptions?
        getter save_snapshot : String?
        getter? include_insights : Bool = false
        getter against : String?
      end

      struct SnapshotStatusInput
        include JSON::Serializable

        getter snapshot : String
        getter cache : GraphCacheOptions?
      end

      struct MapInput
        include JSON::Serializable

        getter files : Array(String)
        getter mode : String = "overview"
        getter path : String?
        getter name : String?
        getter format : String = "markdown"
        @[JSON::Field(key: "include")]
        getter include_patterns : Array(String)?
        getter max_exports : Int32?
        getter cache : Bool | String?
      end

      struct SearchInput
        include JSON::Serializable

        getter query : String
        getter files : Array(String)
        getter top_k : Int32 = 10
        getter languages : Array(String)?
        getter kinds : Array(String)?
      end

      struct ReadSymbolInput
        include JSON::Serializable

        getter files : Array(String)
        getter name : String?
        getter qualified_name : String?
        getter file : String?
      end

      struct CraftInput
        include JSON::Serializable

        getter name : String
        getter domain : String
        getter solver : String
        getter signature : String
        getter skeleton : String
        getter slots : Array(SlotDefJSON)
        getter normalizations : Array(NormalizationDefJSON)
        getter tips : Array(String)?
        getter example : String?
        # ameba:disable Naming/QueryBoolMethods
        getter test : Bool = false
      end

      struct SlotDefJSON
        include JSON::Serializable

        getter name : String
        getter description : String
        getter format : String
      end

      struct NormalizationDefJSON
        include JSON::Serializable

        getter source : String
        getter transform : String
      end

      struct ReviewInput
        include JSON::Serializable

        getter files : Array(String)
        getter focus : String?
        getter entry_points : Array(String)?
        getter delta_against : String?
      end

      struct CrigInput
        include JSON::Serializable

        getter prompt : String
        getter preamble : String?
        getter model : String?
        getter max_turns : Int32 = 0
      end

      # ────────────────────────────────────────────
      # Helper methods to convert from domain objects to JSON types
      # ────────────────────────────────────────────
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
            answers: result.answers.map { |answer| PrologAnswerJSON.new(answer.bindings, answer.formatted) },
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
          slots: template.slots.map { |slot| SlotJSON.new(slot.name, slot.description, slot.format) },
          normalizations: template.normalizations.map { |normalization| NormalizationJSON.new(normalization.source, normalization.transform) },
          tips: template.tips || [] of String,
          example: template.example || ""
        )
      end

      def self.skill_search_result_to_json(result : Skills::SkillSearchResult) : SkillSearchResultJSON
        SkillSearchResultJSON.new(
          template: template_to_json(result.template),
          metadata: skill_metadata_to_json(result.metadata),
          score: result.score
        )
      end

      def self.skill_with_metadata_to_json(item : Skills::SkillWithMetadata) : SkillWithMetadataJSON
        SkillWithMetadataJSON.new(
          template: template_to_json(item.template),
          metadata: skill_metadata_to_json(item.metadata)
        )
      end

      def self.skill_metadata_to_json(metadata : Skills::SkillMetadata) : SkillMetadataJSON
        SkillMetadataJSON.new(
          reuse_count: metadata.reuse_count,
          success_count: metadata.success_count,
          last_used: metadata.last_used.try(&.to_s),
          promoted: metadata.promoted
        )
      end
    end
  end
end
