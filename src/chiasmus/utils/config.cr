# Configuration management for chiasmus
require "json"

module Chiasmus
  module Utils
    class Config
      # Configuration structure
      struct ChiasmusConfig
        include JSON::Serializable

        # Enable auto-discovery of chiasmus-adapter-* packages at startup (default: false)
        @[JSON::Field(key: "adapterDiscovery")]
        property? adapter_discovery : Bool = false

        def initialize(@adapter_discovery = false)
        end

        def adapter_discovery : Bool
          @adapter_discovery
        end
      end

      DEFAULTS = ChiasmusConfig.new

      # Get chiasmus home directory
      # Uses XDG directories if XDG environment variables are set
      def self.chiasmus_home : String
        # Check for explicit CHIASMUS_HOME first
        return ENV["CHIASMUS_HOME"] if ENV["CHIASMUS_HOME"]?

        # Use XDG_CONFIG_HOME if set
        if xdg_config_home = ENV["XDG_CONFIG_HOME"]?
          return File.join(xdg_config_home, "chiasmus")
        end

        # Get home directory from ENV["HOME"]
        home_dir = ENV["HOME"]? || raise "HOME environment variable not set"

        # Fall back to ~/.config/chiasmus for XDG compliance
        # or ~/.chiasmus for backward compatibility
        config_dir = File.join(home_dir, ".config", "chiasmus")

        # Check if ~/.chiasmus exists (legacy location)
        legacy_dir = File.join(home_dir, ".chiasmus")
        if Dir.exists?(legacy_dir) && !Dir.exists?(config_dir)
          return legacy_dir
        end

        # Otherwise use XDG-compliant location
        config_dir
      end

      # Load config from ~/.chiasmus/config.json, falling back to defaults
      def self.load(chiasmus_home : String? = nil) : ChiasmusConfig
        home = chiasmus_home || self.chiasmus_home

        config_path = File.join(home, "config.json")

        return DEFAULTS.dup unless File.exists?(config_path)

        begin
          config_data = File.read(config_path)
          ChiasmusConfig.from_json(config_data)
        rescue ex : JSON::ParseException | File::Error
          # If config file is malformed or unreadable, return defaults
          DEFAULTS.dup
        end
      end

      # Save config to ~/.chiasmus/config.json
      def self.save(config : ChiasmusConfig, chiasmus_home : String? = nil)
        home = chiasmus_home || self.chiasmus_home
        config_dir = File.dirname(File.join(home, "config.json"))

        # Create directory if it doesn't exist
        Dir.mkdir_p(config_dir) unless Dir.exists?(config_dir)

        config_path = File.join(home, "config.json")
        File.write(config_path, config.to_pretty_json)
      end
    end
  end
end
