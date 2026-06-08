require "json"

module Chiasmus
  module Skills
    struct SlotDef
      include JSON::Serializable

      getter name : String
      getter description : String
      getter format : String

      def initialize(@name : String, @description : String, @format : String)
      end
    end

    struct Normalization
      include JSON::Serializable

      getter source : String
      getter transform : String

      def initialize(@source : String, @transform : String)
      end
    end

    struct SkillTemplate
      include JSON::Serializable

      getter name : String
      getter domain : String
      getter solver : Solvers::SolverType
      getter signature : String
      getter skeleton : String
      getter slots : Array(SlotDef)
      getter normalizations : Array(Normalization)
      getter tips : Array(String)?
      getter example : String?

      def initialize(
        @name : String,
        @domain : String,
        @solver : Solvers::SolverType,
        @signature : String,
        @skeleton : String,
        @slots : Array(SlotDef),
        @normalizations : Array(Normalization),
        @tips : Array(String)? = nil,
        @example : String? = nil,
      )
      end
    end

    struct SkillMetadata
      include JSON::Serializable

      getter name : String
      getter reuse_count : Int32
      getter success_count : Int32
      getter last_used : Time?
      getter promoted : Bool

      def initialize(
        @name : String,
        @reuse_count : Int32,
        @success_count : Int32,
        @last_used : Time? = nil,
        @promoted : Bool = false,
      )
      end
    end

    struct SkillWithMetadata
      include JSON::Serializable

      getter template : SkillTemplate
      getter metadata : SkillMetadata

      def initialize(@template : SkillTemplate, @metadata : SkillMetadata)
      end
    end

    struct SkillSearchResult
      include JSON::Serializable

      getter template : SkillTemplate
      getter metadata : SkillMetadata
      getter score : Float64

      def initialize(@template : SkillTemplate, @metadata : SkillMetadata, @score : Float64)
      end
    end
  end
end
