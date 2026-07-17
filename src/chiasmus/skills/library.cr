require "json"
require "bm25"
require "./template_store"
require "../utils/atomic_file"

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

      @@before_metadata_write_hook = nil.as((-> Nil)?)
      @@before_metadata_write_hook_mutex = Mutex.new

      @templates : Hash(String, SkillTemplate)
      @metadata : Hash(String, SkillMetadata)
      @template_order : Array(String)
      @metadata_path : String
      @store : TemplateStore(SkillTemplate)
      @search_engine : Bm25::SearchEngine(String, UInt32, Bm25::DefaultTokenizer)
      @mutex : Mutex
      @metadata_write_mutex : Mutex
      @metadata_persist_requests : Channel(Bool)
      @metadata_flush_requests : Channel(Channel(Bool))
      @metadata_stop_requests : Channel(Bool)
      @closed : Bool
      @close_mutex : Mutex

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
        @mutex = Mutex.new
        @metadata_write_mutex = Mutex.new
        @metadata_persist_requests = Channel(Bool).new(1)
        @metadata_flush_requests = Channel(Channel(Bool)).new
        @metadata_stop_requests = Channel(Bool).new
        @closed = false
        @close_mutex = Mutex.new
        rebuild_search_index
        start_metadata_persistence_worker
      end

      def list : Array(SkillWithMetadata)
        @mutex.synchronize do
          @template_order.compact_map do |name|
            template = @templates[name]?
            next unless template

            SkillWithMetadata.new(
              template: template,
              metadata: unsafe_load_metadata(name)
            )
          end
        end
      end

      def get(name : String) : SkillWithMetadata?
        @mutex.synchronize do
          template = @templates[name]?
          next nil unless template

          SkillWithMetadata.new(
            template: template,
            metadata: unsafe_load_metadata(name)
          )
        end
      end

      def get_related(name : String) : Array(RelatedTemplate)
        Skills.get_related_templates(name)
      end

      def search(query : String, options : SearchOptions = SearchOptions.new) : Array(SkillSearchResult)
        limit = options.limit || 10

        if query.blank?
          return list_all_filtered(options).first(limit)
        end

        @mutex.synchronize do
          @search_engine.search(query, limit: nil).compact_map do |bm25_result|
            name = bm25_result.document.id
            template = @templates[name]?
            next unless template
            next if options.domain && template.domain != options.domain
            next if options.solver && template.solver != options.solver

            SkillSearchResult.new(
              template: template,
              metadata: unsafe_load_metadata(name),
              score: bm25_result.score.to_f64
            )
          end.first(limit)
        end
      end

      private def list_all_filtered(options : SearchOptions) : Array(SkillSearchResult)
        @mutex.synchronize do
          @template_order.compact_map do |tpl_name|
            template = @templates[tpl_name]?
            next unless template
            next if options.domain && template.domain != options.domain
            next if options.solver && template.solver != options.solver

            SkillSearchResult.new(
              template: template,
              metadata: unsafe_load_metadata(tpl_name),
              score: 0.0
            )
          end
        end
      end

      def record_use(name : String, success : Bool) : Nil
        @mutex.synchronize do
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
        save_metadata_async
      end

      def get_metadata(name : String) : SkillMetadata?
        @mutex.synchronize { @metadata[name]? }
      end

      def add_learned(template : SkillTemplate) : Bool
        added = @mutex.synchronize do
          next false if @templates.has_key?(template.name)

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
          true
        end

        return false unless added

        save_metadata_async
        save_templates
        true
      end

      def promote(name : String) : Bool
        promoted = @mutex.synchronize do
          metadata = @metadata[name]?
          next false unless metadata

          @metadata[name] = SkillMetadata.new(
            name: name,
            reuse_count: metadata.reuse_count,
            success_count: metadata.success_count,
            last_used: metadata.last_used,
            promoted: true
          )
          true
        end

        return false unless promoted

        save_metadata_async
        true
      end

      def remove(name : String) : Nil
        @mutex.synchronize do
          @templates.delete(name)
          idx = @template_order.index(name)
          @template_order.reject! { |entry| entry == name }
          @search_engine.remove(idx.to_s) if idx
          @metadata.delete(name)
        end
        save_metadata_async
        save_templates
      end

      def candidates : Array(SkillWithMetadata)
        list.reject(&.metadata.promoted)
      end

      def close : Nil
        @close_mutex.synchronize do
          next if @closed
          @closed = true
          flush_metadata_persistence
          @metadata_stop_requests.send(true)
        end
        save_templates
      end

      def save_metadata : Nil
        payload = @mutex.synchronize { @metadata.values.to_json }
        persist_metadata_payload(payload)
      rescue File::Error
      end

      def save_templates : Nil
        templates = @mutex.synchronize do
          starter_names = starter_template_names
          @templates.values.reject { |t| starter_names.includes?(t.name) }
        end
        @store.save(templates)
      rescue File::Error
      end

      private def starter_template_names : Set(String)
        STARTER_TEMPLATES.map(&.name).to_set
      end

      # Produce the searchable text for a template (BM25 and embeddings rank the same surface)
      def get_template_search_text(template : SkillTemplate) : String
        [
          template.name,
          template.domain,
          template.signature,
          *template.slots.map(&.description),
          *template.normalizations.map { |norm| "#{norm.source} #{norm.transform}" },
        ].join(" ")
      end

      private def build_search_text(template : SkillTemplate) : String
        get_template_search_text(template)
      end

      private def build_document(name : String, template : SkillTemplate) : Bm25::Document(String)
        Bm25::Document(String).new(name, build_search_text(template))
      end

      private def start_metadata_persistence_worker : Nil
        spawn(name: "skill-library-metadata-persist") do
          loop do
            select
            when @metadata_persist_requests.receive
              persist_metadata_until_settled
            when ack = @metadata_flush_requests.receive
              persist_metadata_if_pending
              ack.send(true)
            when @metadata_stop_requests.receive
              break
            end
          end
        end
      end

      private def save_metadata_async : Nil
        select
        when @metadata_persist_requests.send(true)
        else
        end
      end

      private def flush_metadata_persistence : Nil
        ack = Channel(Bool).new(1)
        @metadata_flush_requests.send(ack)
        ack.receive
      end

      private def persist_metadata_until_settled : Nil
        loop do
          save_metadata

          dirty = false
          loop do
            select
            when @metadata_persist_requests.receive
              dirty = true
            else
              break
            end
          end

          break unless dirty
        end
      end

      private def persist_metadata_if_pending : Nil
        dirty = false

        select
        when @metadata_persist_requests.receive
          dirty = true
        else
        end

        persist_metadata_until_settled if dirty
      end

      private def rebuild_search_index : Nil
        @mutex.synchronize do
          @template_order.each do |name|
            template = @templates[name]?
            next unless template
            @search_engine.upsert(build_document(name, template))
          end
        end
      end

      private def unsafe_load_metadata(name : String) : SkillMetadata
        @metadata[name]? || SkillMetadata.new(
          name: name,
          reuse_count: 0,
          success_count: 0,
          last_used: nil,
          promoted: false
        )
      end

      private def persist_metadata_payload(payload : String) : Nil
        @metadata_write_mutex.synchronize do
          self.class.run_before_metadata_write_hook_for_test
          Utils::AtomicFile.write(@metadata_path, payload)
        end
      end

      protected def self.run_before_metadata_write_hook_for_test : Nil
        hook = @@before_metadata_write_hook_mutex.synchronize { @@before_metadata_write_hook }
        hook.try(&.call)
      end

      def self.set_before_metadata_write_hook_for_test(&block : ->) : Nil
        @@before_metadata_write_hook_mutex.synchronize do
          @@before_metadata_write_hook = block
        end
      end

      def self.clear_before_metadata_write_hook_for_test : Nil
        @@before_metadata_write_hook_mutex.synchronize do
          @@before_metadata_write_hook = nil
        end
      end
    end
  end
end
