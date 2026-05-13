require "../extractor"

module Chiasmus
  module Discovery
    struct ProtobufExtractor < QueryExtractor
      def language : String
        "protobuf"
      end

      def extensions : Array(String)
        [".proto"]
      end

      def grammar_language : String
        "proto"
      end

      def queries : Hash(String, String)
        {
          "class" => <<-QUERY,
            (message (message_name) @name) @def
            (enum (enum_name) @name) @def
            (service (service_name) @name) @def
          QUERY
          "function" => "(rpc (rpc_name) @name) @def",
        }
      end

      def predicate_queries : Hash(String, String)
        {
          "definition.package" => "(package (full_ident) @name)",
          "field"              => <<-QUERY,
            (message_body (_) @field)
            (enum_body (enum_field) @field)
          QUERY
        }
      end
    end
  end
end
