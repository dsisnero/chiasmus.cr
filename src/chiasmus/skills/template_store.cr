# Crig-style generic template storage backends.
#
# Abstract base: TemplateStore(T) — defines the contract.
# Implementations: InMemoryTemplateStore, JsonFileTemplateStore.
#
# Pattern: Crig's VectorStoreIndex(M, D) → Domain-specific store per type T.
# Generic over template type T (default: SkillTemplate).

require "json"

module Chiasmus
  module Skills
    abstract class TemplateStore(T)
      abstract def load_all : Array(T)
      abstract def save(templates : Array(T)) : Nil
      abstract def delete(name : String) : Nil
      abstract def has?(name : String) : Bool
    end

    class InMemoryTemplateStore(T) < TemplateStore(T)
      @templates : Hash(String, T)

      def initialize(@templates = Hash(String, T).new)
      end

      def load_all : Array(T)
        @templates.values.dup
      end

      def save(templates : Array(T)) : Nil
        templates.each { |t| @templates[t.name] = t }
      end

      def delete(name : String) : Nil
        @templates.delete(name)
      end

      def has?(name : String) : Bool
        @templates.has_key?(name)
      end
    end

    class JsonFileTemplateStore(T) < TemplateStore(T)
      getter path : String

      def initialize(@path : String)
      end

      def load_all : Array(T)
        return [] of T unless File.exists?(@path)
        raw = File.read(@path)
        return [] of T if raw.strip.empty?
        Array(T).from_json(raw)
      rescue JSON::ParseException
        [] of T
      end

      def save(templates : Array(T)) : Nil
        File.write(@path, templates.to_json)
      rescue File::Error
      end

      def delete(name : String) : Nil
        existing = load_all
        filtered = existing.reject { |t| t.name == name }
        save(filtered)
      end

      def has?(name : String) : Bool
        load_all.any? { |t| t.name == name }
      end
    end
  end
end
