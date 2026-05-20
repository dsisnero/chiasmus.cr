# Ported from vendor/chiasmus/src/formalize/prolog-input.ts
#
# Shared utility for extracting a Prolog query from a spec string.
# Looks for the last line starting with "?-" and separates program from query.

module Chiasmus
  module Formalize
    module PrologInput
      extend self

      def extract_query(spec : String) : NamedTuple(program: String, query: String)
        lines = spec.split('\n')
        program = spec
        query = "true."

        (lines.size - 1).downto(0) do |i|
          trimmed = lines[i].strip
          if trimmed.starts_with?("?-")
            query = trimmed.sub(/^\?\-\s*/, "")
            program = lines[0...i].join('\n').strip
            break
          end
        end

        {program: program, query: query}
      end
    end
  end
end
