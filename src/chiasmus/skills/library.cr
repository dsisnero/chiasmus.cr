require "json"
require "bm25"
require "./template_store"

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
      @store : TemplateStore(SkillTemplate)
      @search_engine : Bm25::SearchEngine(String, UInt32, Bm25::DefaultTokenizer)

      # Crig-style fluent builder
      struct Builder
        @base_path : String?
        @store : TemplateStore(SkillTemplate)?

        def with_base_path(path : String) : self
          @base_path = path
          self
        end

        def with_store(store : TemplateStore(SkillTemplate)) : self
          @store = store
          self
        end

        def build : Library
          base_path = @base_path || Dir.tempdir
          Dir.mkdir_p(base_path)

          store = @store || JsonFileTemplateStore(SkillTemplate).new(File.join(base_path, "skill_templates.json"))
          metadata_path = File.join(base_path, "skill_metadata.json")

          # Load persisted templates from the store, then overlay starters
          persisted = store.load_all
          templates = Hash(String, SkillTemplate).new
          persisted.each { |t| templates[t.name] = t }
          STARTER_TEMPLATES.each { |t| templates[t.name] = t }

          metadata = Library.load_persisted_metadata(metadata_path)
          templates.each_key do |name|
            metadata[name] ||= SkillMetadata.new(
              name: name,
              reuse_count: 0,
              success_count: 0,
              last_used: nil,
              promoted: true
            )
          end

          Library.new(templates, metadata, metadata_path, store)
        end
      end

      # Backward-compatible convenience constructor
      def self.create(base_path : String) : Library
        Builder.new.with_base_path(base_path).build
      end

      # Build a library with a custom store (e.g. InMemory for testing)
      def self.with_store(base_path : String, store : TemplateStore(SkillTemplate)) : Library
        Builder.new.with_base_path(base_path).with_store(store).build
      end

      def self.load_persisted_metadata(path : String) : Hash(String, SkillMetadata)
        return Hash(String, SkillMetadata).new unless File.exists?(path)

        raw = File.read(path)
        return Hash(String, SkillMetadata).new if raw.strip.empty?

        Array(SkillMetadata).from_json(raw)
          .each_with_object(Hash(String, SkillMetadata).new) { |m, acc| acc[m.name] = m }
      rescue JSON::ParseException
        Hash(String, SkillMetadata).new
      end

      def initialize(
        @templates : Hash(String, SkillTemplate),
        @metadata : Hash(String, SkillMetadata),
        @metadata_path : String,
        @store : TemplateStore(SkillTemplate),
      )
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
        save_templates
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
        save_templates
      end

      def candidates : Array(SkillWithMetadata)
        list.reject(&.metadata.promoted)
      end

      def close : Nil
        save_metadata
        save_templates
      end

      def save_metadata : Nil
        File.write(@metadata_path, @metadata.values.to_json)
      rescue File::Error
      end

      def save_templates : Nil
        @store.save(@templates.values.reject { |t| starter_template_names.includes?(t.name) })
      rescue File::Error
      end

      private def starter_template_names : Set(String)
        STARTER_TEMPLATES.map(&.name).to_set
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
