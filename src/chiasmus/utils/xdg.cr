module Chiasmus
  module Utils
    # XDG Base Directory Specification utilities
    module XDG
      extend self

      # Get cache directory for chiasmus
      # XDG: $XDG_CACHE_HOME or ~/.cache
      def cache_home : String
        ENV["XDG_CACHE_HOME"]? || (Path.home / ".cache").to_s
      end

      # Get config directory for chiasmus
      # XDG: $XDG_CONFIG_HOME or ~/.config
      def config_home : String
        ENV["XDG_CONFIG_HOME"]? || (Path.home / ".config").to_s
      end

      # Get data directory for chiasmus
      # XDG: $XDG_DATA_HOME or ~/.local/share
      def data_home : String
        ENV["XDG_DATA_HOME"]? || (Path.home / ".local" / "share").to_s
      end

      # Get runtime directory for chiasmus
      # XDG: $XDG_RUNTIME_DIR (no default, must be set)
      def runtime_dir : String?
        ENV["XDG_RUNTIME_DIR"]?
      end

      # Get chiasmus-specific cache directory
      def chiasmus_cache_dir : String
        File.join(cache_home, "chiasmus")
      end

      # Get chiasmus grammar cache directory
      def grammar_cache_dir : String
        File.join(chiasmus_cache_dir, "grammars")
      end

      # Get chiasmus-specific config directory
      def chiasmus_config_dir : String
        File.join(config_home, "chiasmus")
      end

      # Get chiasmus-specific data directory
      def chiasmus_data_dir : String
        File.join(data_home, "chiasmus")
      end

      # Get tree-sitter config directory (follows tree-sitter shard's logic)
      # Note: tree-sitter uses platform-specific defaults, not pure XDG
      def tree_sitter_config_dir : String
        # tree-sitter shard logic: XDG_CONFIG_HOME if set, otherwise platform default
        if xdg_config = ENV["XDG_CONFIG_HOME"]?
          xdg_config
        else
          {% if flag?(:darwin) %}
            # macOS: ~/Library/Application Support
            (Path.home / "Library" / "Application Support").to_s
          {% else %}
            # Linux/Unix: ~/.config
            (Path.home / ".config").to_s
          {% end %}
        end
      end

      # Get tree-sitter config file path
      def tree_sitter_config_file : String
        File.join(tree_sitter_config_dir, "tree-sitter", "config.json")
      end

      # Ensure all chiasmus directories exist
      def ensure_directories
        Dir.mkdir_p(grammar_cache_dir)
        Dir.mkdir_p(chiasmus_config_dir)
        Dir.mkdir_p(chiasmus_data_dir)

        # Also ensure tree-sitter config directory exists
        tree_sitter_dir = File.join(tree_sitter_config_dir, "tree-sitter")
        Dir.mkdir_p(tree_sitter_dir)
      end

      # Clear chiasmus cache
      def clear_cache
        return unless Dir.exists?(chiasmus_cache_dir)
        FileUtils.rm_rf(chiasmus_cache_dir)
      end

      # Get state directory (for things that should persist but aren't config or cache)
      # XDG: $XDG_STATE_HOME or ~/.local/state
      def state_home : String
        ENV["XDG_STATE_HOME"]? || (Path.home / ".local" / "state").to_s
      end

      def chiasmus_state_dir : String
        File.join(state_home, "chiasmus")
      end
    end
  end
end
