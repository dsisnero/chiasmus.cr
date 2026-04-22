require "json"

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
      TOKEN_NORMALIZATIONS = {
        "contradict" => "contradiction",
        "conflict"   => "contradiction",
        "equival"    => "equivalence",
        "depend"     => "dependency",
        "configur"   => "configuration",
        "permiss"    => "permission",
        "validat"    => "validation",
        "infer"      => "inference",
        "reach"      => "reachability",
        "call"       => "call",
        "function"   => "call",
        "chain"      => "chain",
        "flow"       => "flow",
      }

      @templates : Hash(String, SkillTemplate)
      @metadata : Hash(String, SkillMetadata)
      @template_order : Array(String)
      @metadata_path : String

      def self.create(base_path : String) : Library
        Dir.mkdir_p(base_path)

        templates = Hash(String, SkillTemplate).new
        STARTER_TEMPLATES.each do |template|
          templates[template.name] = template
        end

        metadata_path = File.join(base_path, "skill_metadata.json")
        metadata = load_persisted_metadata(metadata_path)
        templates.each_key do |name|
          metadata[name] ||= SkillMetadata.new(
            name: name,
            reuse_count: 0,
            success_count: 0,
            last_used: nil,
            promoted: true
          )
        end

        library = new(templates, metadata, metadata_path)
        library.save_metadata
        library
      end

      def self.load_persisted_metadata(path : String) : Hash(String, SkillMetadata)
        return Hash(String, SkillMetadata).new unless File.exists?(path)

        payload = JSON.parse(File.read(path)).as_a
        payload.each_with_object(Hash(String, SkillMetadata).new) do |item, acc|
          hash = item.as_h
          name = hash["name"].as_s
          acc[name] = SkillMetadata.new(
            name: name,
            reuse_count: hash["reuse_count"].as_i,
            success_count: hash["success_count"].as_i,
            last_used: parse_time(hash["last_used"]?),
            promoted: hash["promoted"].as_bool
          )
        end
      rescue JSON::ParseException
        Hash(String, SkillMetadata).new
      end

      def self.parse_time(value : JSON::Any?) : Time?
        string_value = value.try(&.as_s?)
        return nil unless string_value

        Time.parse_rfc3339(string_value)
      rescue Time::Format::Error
        nil
      end

      def initialize(@templates : Hash(String, SkillTemplate), @metadata : Hash(String, SkillMetadata), @metadata_path : String)
        @template_order = @templates.keys.to_a
      end

      def list : Array(SkillWithMetadata)
        @template_order.compact_map do |name|
          template = @templates[name]?
          next unless template

          SkillWithMetadata.new(
            template: template,
            metadata: load_metadata(name)
          )
        end
      end

      def get(name : String) : SkillWithMetadata?
        template = @templates[name]?
        return nil unless template

        SkillWithMetadata.new(
          template: template,
          metadata: load_metadata(name)
        )
      end

      def get_related(name : String) : Array(RelatedTemplate)
        Skills.get_related_templates(name)
      end

      def search(query : String, options : SearchOptions = SearchOptions.new) : Array(SkillSearchResult)
        limit = options.limit || 10

        results = @template_order.compact_map do |name|
          template = @templates[name]?
          next unless template
          next if options.domain && template.domain != options.domain
          next if options.solver && template.solver != options.solver

          SkillSearchResult.new(
            template: template,
            metadata: load_metadata(name),
            score: calculate_relevance_score(template, query)
          )
        end

        results.sort_by(&.score).reverse!.first(limit)
      end

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
        save_metadata
      end

      def get_metadata(name : String) : SkillMetadata?
        @metadata[name]?
      end

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
        save_metadata
        true
      end

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
        save_metadata
        true
      end

      def remove(name : String) : Nil
        @templates.delete(name)
        @template_order.reject! { |entry| entry == name }
        @metadata.delete(name)
        save_metadata
      end

      def candidates : Array(SkillWithMetadata)
        list.reject(&.metadata.promoted)
      end

      def close : Nil
        save_metadata
      end

      def save_metadata : Nil
        payload = @metadata.values.map do |metadata|
          {
            "name"          => metadata.name,
            "reuse_count"   => metadata.reuse_count,
            "success_count" => metadata.success_count,
            "last_used"     => metadata.last_used.try(&.to_rfc3339),
            "promoted"      => metadata.promoted,
          }
        end
        File.write(@metadata_path, payload.to_json)
      rescue File::Error
        # Sandboxed environments may not allow writes under the configured home dir.
      end

      private def calculate_relevance_score(template : SkillTemplate, query : String) : Float64
        return 0.0 if query.blank?

        query_terms = tokenize(query)
        score_texts = {
          4.0 => [template.name, template.domain],
          3.0 => [template.signature],
          2.0 => template.slots.map(&.description),
          1.5 => template.normalizations.map { |normalization| "#{normalization.source} #{normalization.transform}" },
          1.0 => template.tips || [] of String,
        }

        score = 0.0
        score_texts.each do |weight, texts|
          haystack = tokenize(texts.join(" "))
          next if haystack.empty?

          query_terms.each do |term|
            score += weight if haystack.includes?(term)
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

      private def tokenize(text : String) : Array(String)
        text.downcase
          .gsub(/[^a-z0-9]+/, " ")
          .split(/\s+/)
          .reject(&.empty?)
          .map { |token| normalize_token(token) }
          .uniq!
      end

      private def normalize_token(token : String) : String
        TOKEN_NORMALIZATIONS.each do |prefix, normalized|
          return normalized if token.starts_with?(prefix)
        end

        token
      end
    end
  end
end
