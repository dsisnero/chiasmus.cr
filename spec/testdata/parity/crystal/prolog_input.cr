module SpecParity
  record PrologQuery, program : String, query : String

  def self.extract_prolog_query(spec : String) : PrologQuery
    lines = spec.lines
    program = spec
    query = "true."

    (lines.size - 1).downto(0) do |index|
      trimmed = lines[index].strip
      next unless trimmed.starts_with?("?-")

      query = trimmed.sub(/^\?\-\s*/, "")
      program = lines[0...index].join.strip
      break
    end

    PrologQuery.new(program: program, query: query)
  end
end
