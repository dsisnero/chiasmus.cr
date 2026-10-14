require "json"
require "openssl"
require "./span"

module Chiasmus
  module Graph
    # Stable identity inputs for a declaration within one source language.
    # Location is deliberately absent; it belongs to OccurrenceIdentityInput instead.
    record DeclarationIdentityInput,
      language : String,
      kind : String,
      name : String,
      namespace : String? = nil,
      owner_chain : Array(String) = [] of String,
      overload_key : String? = nil,
      disambiguator : String? = nil

    # Location-bearing identity for one syntax occurrence in a logical checkout.
    record OccurrenceIdentityInput,
      logical_relative_path : String,
      span : Span,
      ast_role : String

    # Versioned IDs local to a source universe. These are not cross-language
    # PortConceptIds; correspondence must be established by parity matching.
    module DeclarationIdentity
      VERSION = "v1"

      # Builds a declaration key independent of checkout root and source span.
      def self.declaration_id(input : DeclarationIdentityInput) : String
        fields = [
          VERSION,
          normalize(input.language),
          normalize_optional(input.namespace),
          input.owner_chain.map { |owner| normalize(owner) },
          normalize(input.kind),
          normalize(input.name),
          normalize_optional(input.overload_key).try { |key| normalize_signature(key) },
          normalize_optional(input.disambiguator),
        ]
        "decl:v1:#{digest(fields)}"
      end

      # Builds an occurrence key that changes when path, span, or AST role moves.
      def self.occurrence_id(input : OccurrenceIdentityInput) : String
        fields = [
          VERSION,
          normalize_relative_path(input.logical_relative_path),
          input.span.start_byte,
          input.span.end_byte,
          input.span.start_line,
          input.span.start_column,
          input.span.end_line,
          input.span.end_column,
          normalize(input.ast_role),
        ]
        "occ:v1:#{digest(fields)}"
      end

      private def self.digest(fields) : String
        OpenSSL::Digest.new("SHA256").update(fields.to_json).final.hexstring
      end

      private def self.normalize(value : String) : String
        value.strip
      end

      private def self.normalize_optional(value : String?) : String?
        value.try { |item| normalize(item) }
      end

      private def self.normalize_signature(value : String) : String
        value.split.join(' ')
      end

      private def self.normalize_relative_path(path : String) : String
        normalized = path.gsub('\\', '/').lchop("./")
        raise ArgumentError.new("occurrence path must be relative") if normalized.starts_with?('/')
        raise ArgumentError.new("occurrence path cannot traverse parents") if normalized.split('/').includes?("..")
        normalized
      end
    end
  end
end
