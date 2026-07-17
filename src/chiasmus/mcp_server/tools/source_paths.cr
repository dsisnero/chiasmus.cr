module Chiasmus
  module MCPServer
    module Tools
      module SourcePaths
        extend self

        def normalize_file_inputs!(paths : Array(String), argument_name : String = "files") : Array(String)
          expanded = paths.map { |path| File.expand_path(path) }
          directory_inputs = expanded.select { |path| Dir.exists?(path) }

          return expanded if directory_inputs.empty?

          raise ArgumentError.new(
            "`#{argument_name}` must contain source file paths, not directories. " \
            "Directory inputs: #{directory_inputs.join(", ")}. Pass concrete source files."
          )
        end
      end
    end
  end
end
