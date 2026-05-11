require "json"
require "bm25"

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
      @search_engine : Bm25::SearchEngine(String, UInt32, Bm25::DefaultTokenizer)

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

        tokenizer = Bm25::DefaultTokenizer.new(stemming: true, stopwords: true, normalization: true)
        embedder = Bm25::Embedder(UInt32, Bm25::DefaultTokenizer).new(
          tokenizer,
          Bm25::U32Embedder.new,
        )
        @search_engine = Bm25::SearchEngine(String, UInt32, Bm25::DefaultTokenizer).new(embedder)
        rebuild_search_index
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

        if query.blank?
          return list_all_filtered(options).first(limit)
        end

        @search_engine.search(query, limit: nil).compact_map do |bm25_result|
          name = bm25_result.document.id
          template = @templates[name]?
          next unless template
          next if options.domain && template.domain != options.domain
          next if options.solver && template.solver != options.solver

          SkillSearchResult.new(
            template: template,
            metadata: load_metadata(name),
            score: bm25_result.score.to_f64
          )
        end.first(limit)
      end

      private def list_all_filtered(options : SearchOptions) : Array(SkillSearchResult)
        @template_order.compact_map do |tpl_name|
          template = @templates[tpl_name]?
          next unless template
          next if options.domain && template.domain != options.domain
          next if options.solver && template.solver != options.solver

          SkillSearchResult.new(
            template: template,
            metadata: load_metadata(tpl_name),
            score: 0.0
          )
        end
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
        @search_engine.upsert(build_document(template.name, template))
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
        idx = @template_order.index(name)
        @template_order.reject! { |entry| entry == name }
        @search_engine.remove(idx.to_s) if idx
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

      private def build_search_text(template : SkillTemplate) : String
        [
          template.name,
          template.domain,
          template.signature,
          *template.slots.map(&.description),
          *template.normalizations.map { |norm| "#{norm.source} #{norm.transform}" },
          *(template.tips || [] of String),
        ].join(" ")
      end

      private def build_document(name : String, template : SkillTemplate) : Bm25::Document(String)
        Bm25::Document(String).new(name, build_search_text(template))
      end

      private def rebuild_search_index : Nil
        @template_order.each do |name|
          template = @templates[name]?
          next unless template
          @search_engine.upsert(build_document(name, template))
        end
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
