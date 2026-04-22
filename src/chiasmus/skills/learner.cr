require "json"
require "../utils/config"

module Chiasmus
  module Skills
    class Learner
      PROMOTION_THRESHOLD        =   3
      PROMOTION_SUCCESS_RATE     = 0.6
      DEDUP_SIMILARITY_THRESHOLD = 0.7

      EXTRACT_SYSTEM = <<-TEXT
      Extract reusable template from verified spec.

      Concrete values -> {{SLOT:name}} markers. Name each slot. Write general signature. Suggest normalizations.

      Return JSON only - no fences, no explanation:
      {"name":"kebab-case","domain":"authorization|configuration|dependency|validation|rules|analysis","signature":"what class of problems this solves","slots":[{"name":"x","description":"what","format":"example"}],"normalizations":[{"source":"format","transform":"how"}],"skeleton":"template with {{SLOT:name}}"}
      TEXT

      record LearnResult,
        template_name : String,
        template : SkillTemplate

      alias Extractor = Proc(Solvers::SolverType, String, String, String)

      @library : Library
      @extractor : Extractor?

      def initialize(@library : Library = Library.create(File.join(Utils::Config.chiasmus_home, "skills")), @extractor : Extractor? = nil)
      end

      def extract_template(solver : Solvers::SolverType, verified_spec : String, problem_description : String) : SkillTemplate?
        response = extractor.call(solver, verified_spec, problem_description)
        template = parse_template_response(response, solver)
        return nil unless template
        return nil if duplicate?(template)
        return nil unless @library.add_learned(template)

        template
      end

      def check_promotions : Nil
        @library.list.each do |item|
          next if item.metadata.promoted
          next if item.metadata.reuse_count < PROMOTION_THRESHOLD

          success_rate = if item.metadata.reuse_count.zero?
                           0.0
                         else
                           item.metadata.success_count.to_f / item.metadata.reuse_count
                         end
          next unless success_rate >= PROMOTION_SUCCESS_RATE

          @library.promote(item.template.name)
        end
      end

      def self.learn_from_solution(
        solver : Solvers::SolverType,
        spec : String,
        problem : String,
        library : Library = Library.create(File.join(Utils::Config.chiasmus_home, "skills")),
        extractor : Extractor? = nil,
      ) : LearnResult
        learner = new(library, extractor)
        template = learner.extract_template(solver, spec, problem)
        raise "Template rejected or could not be extracted" unless template

        LearnResult.new(template_name: template.name, template: template)
      end

      private def extractor : Extractor
        @extractor || raise "Skill learner extractor not configured"
      end

      private def parse_template_response(response : String, solver : Solvers::SolverType) : SkillTemplate?
        cleaned = response
          .gsub(/^```(?:json)?\n?/m, "")
          .gsub(/^```\n?/m, "")
          .strip

        parsed = JSON.parse(cleaned).as_h
        return nil unless valid_required_fields?(parsed)

        slots = parse_slots(parsed["slots"]?.try(&.as_a) || [] of JSON::Any)
        normalizations = parse_normalizations(parsed["normalizations"]?.try(&.as_a) || [] of JSON::Any)

        SkillTemplate.new(
          name: parsed["name"].as_s,
          domain: parsed["domain"].as_s,
          solver: solver,
          signature: parsed["signature"].as_s,
          skeleton: parsed["skeleton"].as_s,
          slots: slots,
          normalizations: normalizations
        )
      rescue JSON::ParseException | TypeCastError
        nil
      end

      private def valid_required_fields?(parsed : Hash(String, JSON::Any)) : Bool
        !!parsed["name"]?.try(&.as_s?) &&
          !!parsed["domain"]?.try(&.as_s?) &&
          !!parsed["signature"]?.try(&.as_s?) &&
          !!parsed["skeleton"]?.try(&.as_s?) &&
          !!parsed["slots"]?.try(&.as_a?) &&
          !!parsed["normalizations"]?.try(&.as_a?)
      end

      private def parse_slots(items : Array(JSON::Any)) : Array(SlotDef)
        items.compact_map do |item|
          hash = item.as_h?
          next unless hash

          name = hash["name"]?.try(&.as_s?)
          description = hash["description"]?.try(&.as_s?)
          format = hash["format"]?.try(&.as_s?)
          next unless name && description && format

          SlotDef.new(name: name, description: description, format: format)
        end
      end

      private def parse_normalizations(items : Array(JSON::Any)) : Array(Normalization)
        items.compact_map do |item|
          hash = item.as_h?
          next unless hash

          source = hash["source"]?.try(&.as_s?)
          transform = hash["transform"]?.try(&.as_s?)
          next unless source && transform

          Normalization.new(source: source, transform: transform)
        end
      end

      private def duplicate?(candidate : SkillTemplate) : Bool
        @library.search(candidate.signature, SearchOptions.new(limit: 3)).any? do |result|
          text_similarity(candidate.signature, result.template.signature) > DEDUP_SIMILARITY_THRESHOLD
        end
      end

      private def text_similarity(left : String, right : String) : Float64
        words_left = tokenize(left)
        words_right = tokenize(right)
        intersection = (words_left & words_right).size
        union = (words_left | words_right).size
        union.zero? ? 0.0 : intersection.to_f / union
      end

      private def tokenize(text : String) : Array(String)
        text.downcase.split(/\s+/).reject(&.empty?).uniq!
      end
    end
  end
end
