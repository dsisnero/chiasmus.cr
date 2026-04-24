require "../utils/xdg"

module Chiasmus
  module Graph
    module Parser
      class Environment
        def ensure_tree_sitter_config : Nil
          config_dir = Utils::XDG.tree_sitter_config_dir
          tree_sitter_config_dir = File.join(config_dir, "tree-sitter")
          Dir.mkdir_p(tree_sitter_config_dir)

          config_file = File.join(tree_sitter_config_dir, "config.json")
          return if File.exists?(config_file)

          parser_dirs = default_parser_directories.select { |dir| Dir.exists?(dir) }
          File.write(config_file, {"parser-directories" => parser_dirs}.to_json)
        rescue File::Error
        end

        private def default_parser_directories : Array(String)
          parser_dirs = [File.expand_path("../../../vendor/grammars", __DIR__)]
          {% if flag?(:darwin) %}
            parser_dirs << "/usr/local/lib"
            parser_dirs << "#{ENV["HOME"]}/.local/lib"
          {% else %}
            parser_dirs << "/usr/lib"
            parser_dirs << "/usr/local/lib"
            parser_dirs << "#{ENV["HOME"]}/.local/lib"
          {% end %}
          parser_dirs
        end
      end
    end
  end
end
