module Chiasmus
  module Skills
    class SearchOptions
      property domain : String?
      property solver : Solvers::SolverType?
      property limit : Int32?

      def initialize(@domain = nil, @solver = nil, @limit = nil)
      end
    end

    class Library
      @templates : Hash(String, SkillTemplate)
      @metadata : Hash(String, SkillMetadata)
      @template_order : Array(String)

      def self.create(base_path : String) : Library
        Dir.mkdir_p(base_path)

        # Load starter templates (simplified for now)
        templates = Hash(String, SkillTemplate).new

        # TODO: Load actual starter templates
        # For now, create a minimal template
        templates["policy-contradiction"] = SkillTemplate.new(
          name: "policy-contradiction",
          domain: "authorization",
          solver: Solvers::SolverType::Z3,
          signature: "Detect contradictory authorization rules",
          skeleton: "(declare-const {{SLOT:rule1}} Bool)\n(declare-const {{SLOT:rule2}} Bool)\n(assert (and {{SLOT:rule1}} {{SLOT:rule2}}))",
          slots: [
            SlotDef.new(name: "rule1", description: "First authorization rule", format: "Boolean expression"),
            SlotDef.new(name: "rule2", description: "Second authorization rule", format: "Boolean expression")
          ],
          normalizations: [
            Normalization.new(source: "natural language rule", transform: "Convert to Boolean logic")
          ],
          tips: ["Use (= flag (or ...)) not (=> ... flag) for Z3"],
          example: nil
        )

        # Create metadata
        metadata = Hash(String, SkillMetadata).new
        templates.each_key do |name|
          metadata[name] = SkillMetadata.new(
            name: name,
            reuse_count: 0,
            success_count: 0,
            last_used: nil,
            promoted: true
          )
        end

        new(templates, metadata)
      end

      def initialize(@templates : Hash(String, SkillTemplate), @metadata : Hash(String, SkillMetadata))
        @template_order = @templates.keys.to_a
      end

      # List all templates with metadata
      def list : Array(SkillWithMetadata)
        @templates.map do |name, template|
          SkillWithMetadata.new(
            template: template,
            metadata: load_metadata(name)
          )
        end.to_a
      end

      # Get a single template by name
      def get(name : String) : SkillWithMetadata?
        template = @templates[name]?
        return nil unless template

        SkillWithMetadata.new(
          template: template,
          metadata: load_metadata(name)
        )
      end

      # Search templates by natural language query (simplified)
      def search(query : String, options : SearchOptions = SearchOptions.new) : Array(SkillSearchResult)
        limit = options.limit || 10
        results = [] of SkillSearchResult

        # Simple keyword matching for now
        @template_order.each do |name|
          template = @templates[name]

          # Filter by domain and solver if specified
          if options.domain && template.domain != options.domain
            next
          end

          if options.solver && template.solver != options.solver
            next
          end

          # Simple relevance scoring
          score = calculate_relevance_score(template, query)

          results << SkillSearchResult.new(
            template: template,
            metadata: load_metadata(name),
            score: score
          )
        end

        # Sort by score and limit
        results.sort_by(&.score).reverse.first(limit)
      end

      # Record a template use (success or failure)
      def record_use(name : String, success : Bool) : Nil
        metadata = @metadata[name]?
        return unless metadata

        @metadata[name] = SkillMetadata.new(
          name: name,
          reuse_count: metadata.reuse_count + 1,
          success_count: metadata.success_count + (success ? 1 : 0),
          last_used: Time.utc,
          promoted: metadata.promoted
        )
      end

      # Get metadata for a template
      def get_metadata(name : String) : SkillMetadata?
        @metadata[name]?
      end

      # Add a learned (candidate) template to the library
      def add_learned(template : SkillTemplate) : Bool
        return false if @templates.has_key?(template.name)

        @templates[template.name] = template
        @template_order << template.name

        @metadata[template.name] = SkillMetadata.new(
          name: template.name,
          reuse_count: 0,
          success_count: 0,
          last_used: nil,
          promoted: false
        )
        true
      end

      # Promote a candidate template to starter status
      def promote(name : String) : Bool
        metadata = @metadata[name]?
        return false unless metadata

        @metadata[name] = SkillMetadata.new(
          name: name,
          reuse_count: metadata.reuse_count,
          success_count: metadata.success_count,
          last_used: metadata.last_used,
          promoted: true
        )
        true
      end

      # Get candidate templates (not promoted)
      def candidates : Array(SkillWithMetadata)
        list.select do |swm|
          !swm.metadata.promoted
        end
      end

      private def calculate_relevance_score(template : SkillTemplate, query : String) : Float64
        # Simple keyword matching
        text_to_search = [
          template.name,
          template.domain,
          template.signature,
          *template.slots.map(&.description),
          *template.normalizations.map { |n| "#{n.source} #{n.transform}" }
        ].join(" ").downcase

        query_terms = query.downcase.split(/\s+/)

        score = 0.0
        query_terms.each do |term|
          if text_to_search.includes?(term)
            score += 1.0
          end
        end

        score
      end

      private def load_metadata(name : String) : SkillMetadata
        @metadata[name]? || SkillMetadata.new(
          name: name,
          reuse_count: 0,
          success_count: 0,
          last_used: nil,
          promoted: false
        )
      end
    end
  end
end