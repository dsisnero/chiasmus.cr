# Ported from vendor/chiasmus/src/graph/suffix-index.ts (MIT, pi-code-graph)
#
# Suffix-based import resolution. Imports in TS/JS can omit the
# extension and use shorter path suffixes; this index maps each known
# file to every suffix of its path so imports like "./foo" or
# "lib/bar" can resolve to the canonical file path seen by the
# extraction pass.

module Chiasmus
  module Graph
    CANDIDATE_EXTS = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]
    STRIP_EXT_RE   = /\.(tsx?|jsx?|mjs|cjs|vue|py|java|kt|kts|c|h|cpp|hpp|cc|cxx|hxx|hh|cs|go|rs|php|phtml|swift|rb|lua)$/i

    record SuffixIndex,
      exact : Hash(String, String),
      lower : Hash(String, String),
      known : Set(String) do
      def get(suffix : String) : String?
        @exact[suffix]?
      end

      def get_insensitive(suffix : String) : String?
        @lower[suffix.downcase]?
      end

      def size : Int32
        @exact.size
      end

      def has_module_qn?(qn : String) : Bool
        @known.includes?(qn)
      end

      def self.empty : SuffixIndex
        new(
          Hash(String, String).new,
          Hash(String, String).new,
          Set(String).new
        )
      end

      def self.build(repo_path : String, file_paths : Enumerable(String)) : SuffixIndex
        exact = Hash(String, String).new
        lower = Hash(String, String).new
        known = Set(String).new

        file_paths.each do |fp|
          rel = compute_relative(repo_path, fp)
          next if rel.empty? || rel.starts_with?("..")

          module_qn = rel
          known << module_qn

          no_ext = rel.sub(STRIP_EXT_RE, "")
          no_index = no_ext.sub(/\/index$/i, "")

          parts = rel.split('/').reject(&.empty?)
          parts_no_ext = no_ext.split('/').reject(&.empty?)
          parts_no_index = no_index.split('/').reject(&.empty?)

          (0...parts.size).each { |j| add_key(exact, lower, parts[j..].join('/'), module_qn) }
          (0...parts_no_ext.size).each { |j| add_key(exact, lower, parts_no_ext[j..].join('/'), module_qn) }
          (0...parts_no_index.size).each { |j| add_key(exact, lower, parts_no_index[j..].join('/'), module_qn) }
        end

        new(exact, lower, known)
      end

      def resolve_import(import_path : String, primary_guess : String?) : String?
        return nil if size == 0

        candidates = [] of Array(String)

        if primary_guess
          cleaned = normalize_rel(primary_guess).sub(STRIP_EXT_RE, "")
          parts = cleaned.split('/').reject(&.empty?)
          candidates << parts unless parts.empty?
        end

        cleaned_import = normalize_rel(import_path)
          .sub(STRIP_EXT_RE, "")
          .sub(/^\.\/+/, "")
        import_parts = cleaned_import.split('/').reject { |p| p.empty? || p == "." || p == ".." }
        candidates << import_parts unless import_parts.empty?

        candidates.each do |parts|
          (0...parts.size).each do |i|
            suffix = parts[i..].join('/')
            next if suffix.empty?

            CANDIDATE_EXTS.each do |ext|
              hit = get(suffix + ext) || get_insensitive(suffix + ext)
              return hit if hit

              idx_hit = get(suffix + "/index" + ext) || get_insensitive(suffix + "/index" + ext)
              return idx_hit if idx_hit
            end

            direct = get(suffix) || get_insensitive(suffix)
            return direct if direct
          end
        end

        nil
      end

      def self.normalize_rel(p : String) : String
        p.gsub('\\', '/')
      end

      def normalize_rel(p : String) : String
        SuffixIndex.normalize_rel(p)
      end

      def self.compute_relative(repo_path : String, fp : String) : String
        prefix = normalize_rel(repo_path).rstrip('/') + "/"
        normalized = normalize_rel(fp)
        if normalized.starts_with?(prefix)
          normalized[prefix.size..]
        else
          ""
        end
      end

      def self.add_key(exact : Hash(String, String), lower : Hash(String, String), key : String, module_qn : String) : Nil
        return if key.empty?
        exact[key] = module_qn unless exact.has_key?(key)
        lc = key.downcase
        lower[lc] = module_qn unless lower.has_key?(lc)
      end
    end
  end
end
