module Chiasmus
  module Parity
    module Naming
      extend self

      def normalized_key(name : String) : String
        segments(name).map { |segment| normalize_token(segment) }
          .reject(&.empty?)
          .join(".")
      end

      def normalized_simple(name : String) : String
        pieces = segments(name)
        return "" if pieces.empty?
        normalize_token(pieces.last)
      end

      def normalized_owner(name : String) : String
        pieces = segments(name)
        return "" if pieces.size < 2
        pieces[0...-1].map { |segment| normalize_token(segment) }
          .reject(&.empty?)
          .join(".")
      end

      def normalize_token(token : String) : String
        cleaned = token.gsub(/^@+/, "")
        cleaned = cleaned.gsub("+", "_plus_")
        cleaned = cleaned.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        cleaned = cleaned.gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        cleaned = cleaned.gsub(/[^A-Za-z0-9]+/, "_")
        cleaned = cleaned.downcase
        cleaned = cleaned.gsub(/(?:_escaped|escaped)\z/, "")
        cleaned.gsub(/^_+|_+$/, "").gsub(/_+/, "_")
      end

      private def segments(name : String) : Array(String)
        return [name] if name.includes?(' ')
        return name.split(/::|\./) if name.includes?("::") || name.includes?('.')
        [name]
      end
    end
  end
end
