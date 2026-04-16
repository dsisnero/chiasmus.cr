module Chiasmus
  module Skills
    # A slot in a template skeleton that must be filled
    record SlotDef,
      # Slot name, matches {{SLOT:name}} in skeleton
      name : String,
      # What this slot expects
      description : String,
      # Expected format/type hint
      format : String

    # A normalization recipe for mapping domain inputs to slot values
    record Normalization,
      # What kind of input this handles
      source : String,
      # How to transform it
      transform : String

    # A reusable formalization template
    record SkillTemplate,
      # Unique identifier
      name : String,
      # Problem domain (authorization, configuration, dependency, validation, rules, analysis)
      domain : String,
      # Which solver this targets
      solver : Solvers::SolverType,
      # Natural language description for search/matching
      signature : String,
      # The formal spec with {{SLOT:name}} markers
      skeleton : String,
      # Slots that need to be filled
      slots : Array(SlotDef),
      # Known normalization recipes
      normalizations : Array(Normalization),
      # Encoding tips and pitfalls specific to this template
      tips : Array(String)? = nil,
      # A complete worked example showing a filled version of this template
      example : String? = nil

    # Runtime metadata tracked per template
    record SkillMetadata,
      name : String,
      reuse_count : Int32,
      success_count : Int32,
      last_used : Time?,
      promoted : Bool

    # Template with its metadata attached
    record SkillWithMetadata,
      template : SkillTemplate,
      metadata : SkillMetadata

    # Search result from the skill library
    record SkillSearchResult,
      template : SkillTemplate,
      metadata : SkillMetadata,
      score : Float64
  end
end
