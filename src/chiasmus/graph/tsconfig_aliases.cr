# Ported from vendor/chiasmus/src/graph/tsconfig-aliases.ts (MIT, pi-code-graph)
#
# tsconfig.json path-alias resolver.
# Parses TypeScript `compilerOptions.paths` (and `baseUrl`) so that
# imports like `@/components/Button` can be rewritten to a repo-relative
# path (`src/components/Button`) before normal module resolution runs.
# Follows `extends` chains and is cycle-safe.

require "json"
require "path"

module Chiasmus
  module Graph
    class TsconfigAliasMap
      getter has_aliases : Bool
      getter size : Int32
      @rewrite_fun : String -> String | Nil

      def initialize(
        @has_aliases : Bool,
        @size : Int32,
        @rewrite_fun : String -> String | Nil,
      )
      end

      def rewrite(import_path : String) : String?
        @rewrite_fun.call(import_path)
      end

      def self.empty : TsconfigAliasMap
        new(
          has_aliases: false,
          size: 0,
          rewrite_fun: ->(_s : String) : String? { nil },
        )
      end
    end

    module TsconfigAliases
      extend self

      private record CompiledAlias,
        prefix : String,
        is_glob : Bool,
        exact : String,
        target_prefix : String,
        target_exact : String

      alias RawPaths = Hash(String, Array(String) | String)

      # --- JSONC comment stripping ---

      private def strip_json_comments(src : String) : String
        src
          .gsub(/\/\*[\s\S]*?\*\//, "")
          .gsub(/^\/\/.*$/, "")
      end

      # --- Load and merge (recursive extends, cycle-safe) ---

      private def load_and_merge(file_path : String, seen : Set(String)? = nil) : Tuple(String?, RawPaths, String)?
        seen ||= Set(String).new
        abs_path = File.expand_path(file_path)
        return nil if seen.includes?(abs_path)
        seen << abs_path

        cfg = try_read_json(abs_path)
        return nil unless cfg

        config_dir = File.dirname(abs_path)

        inherited : Tuple(String?, RawPaths, String)? = nil
        if extends = cfg["extends"]?.try(&.as_s?)
          ext_path = extends
          ext_path += ".json" unless ext_path.ends_with?(".json")
          abs_ext = if Path.new(ext_path).absolute?
                      ext_path
                    else
                      File.expand_path(File.join(config_dir, ext_path))
                    end
          inherited = load_and_merge(abs_ext, seen)
        end

        co = cfg["compilerOptions"]?.try(&.as_h?) || Hash(String, JSON::Any).new
        base_url = co["baseUrl"]?.try(&.as_s?) || inherited.try(&.[0])
        paths : RawPaths = Hash(String, Array(String) | String).new
        if inherited
          inherited.not_nil![1].each { |k, v| paths[k] = v }
        end
        if co_paths = co["paths"]?.try(&.as_h?)
          co_paths.each do |k, v|
            paths[k] = v.as_a.map(&.as_s)
          end
        end

        effective_config_dir = if co.has_key?("baseUrl")
                                 config_dir
                               else
                                 inherited.try(&.[2]) || config_dir
                               end

        {base_url, paths, effective_config_dir}
      end

      private def try_read_json(file_path : String) : Hash(String, JSON::Any)?
        return nil unless File.exists?(file_path)
        raw = File.read(file_path)
        JSON.parse(strip_json_comments(raw)).as_h?
      rescue
        nil
      end

      # --- Main entry point ---

      def load_tsconfig_aliases(repo_path : String) : TsconfigAliasMap
        candidates = [
          "tsconfig.json",
          "tsconfig.app.json",
          "tsconfig.base.json",
          "jsconfig.json",
        ]

        candidates.each do |filename|
          merged = load_and_merge(File.join(repo_path, filename))
          next unless merged
          base_url, raw_paths, merged_config_dir = merged
          next if raw_paths.empty?

          base = base_url || "."
          base_abs = File.expand_path(base, merged_config_dir)

          repo_rel = ->(p : String) : String {
            abs = File.expand_path(p, base_abs)
            rel = if abs.starts_with?(repo_path)
                    abs[repo_path.size..]
                  else
                    abs
                  end
            rel = rel.lstrip("/\\")
            rel.gsub('\\', '/')
          }

          compiled = [] of CompiledAlias
          raw_paths.each do |pattern, targets|
            target_arr = targets.is_a?(Array) ? targets.map(&.to_s) : [targets.to_s]
            next if target_arr.empty?
            raw_target = target_arr[0]
            is_glob = pattern.ends_with?("/*")
            exact = is_glob ? pattern.rchop("/*") : pattern
            prefix = is_glob ? pattern.rchop("*") : pattern

            target_exact = repo_rel.call(
              raw_target.ends_with?("/*") ? raw_target.rchop("/*") : raw_target,
            )
            raw_no_star = raw_target.ends_with?("/*") ? raw_target.rchop("*") : raw_target
            target_prefix = repo_rel.call(raw_no_star) + (raw_target.ends_with?("/*") ? "/" : "")

            compiled << CompiledAlias.new(
              prefix: prefix,
              is_glob: is_glob,
              exact: exact,
              target_prefix: target_prefix,
              target_exact: target_exact,
            )
          end

          next if compiled.empty?
          compiled.sort_by! { |a| -a.prefix.size }

          return TsconfigAliasMap.new(
            has_aliases: true,
            size: compiled.size,
            rewrite_fun: ->(import_path : String) : String? {
              compiled.each do |a|
                if a.is_glob
                  return a.target_exact if import_path == a.exact
                  if import_path.starts_with?(a.prefix)
                    rest = import_path[a.prefix.size..]
                    return (a.target_prefix + rest).gsub(/\/+/, "/")
                  end
                elsif import_path == a.exact
                  return a.target_exact
                end
              end
              nil
            },
          )
        end

        TsconfigAliasMap.empty
      end
    end
  end
end
