# Configuration management for chiasmus
require "json"
require "yaml"
require "./atomic_file"

module Chiasmus
  module Utils
    class Config
      # Configuration structure
      struct ChiasmusConfig
        include JSON::Serializable

        def initialize
        end
      end

      struct RepoParityConfig
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        struct RepoParityEquivalence
          include YAML::Serializable
          include YAML::Serializable::Unmapped

          @[YAML::Field(key: "source_path")]
          property source_path : String?

          @[YAML::Field(key: "target_path")]
          property target_path : String?

          @[YAML::Field(key: "source_namespace")]
          property source_namespace : String?

          @[YAML::Field(key: "target_namespace")]
          property target_namespace : String?

          def initialize(
            @source_path : String? = nil,
            @target_path : String? = nil,
            @source_namespace : String? = nil,
            @target_namespace : String? = nil,
          )
          end
        end

        @[YAML::Field(key: "vendor_src")]
        property vendor_src : String?

        @[YAML::Field(key: "target_src")]
        property target_src : Array(String)?

        @[YAML::Field(key: "equivalences")]
        property equivalences : Array(RepoParityEquivalence)?

        def initialize(
          @vendor_src : String? = nil,
          @target_src : Array(String)? = nil,
          @equivalences : Array(RepoParityEquivalence)? = nil,
        )
        end
      end

      RepoParityEquivalence = RepoParityConfig::RepoParityEquivalence

      struct RepoConfig
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        property parity : RepoParityConfig?

        def initialize(@parity : RepoParityConfig? = nil)
        end
      end

      DEFAULTS            = ChiasmusConfig.new
      DEFAULT_REPO_CONFIG = RepoConfig.new

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

      def self.repo_config_dir(repo_root : String = Dir.current) : String
        File.join(repo_root, ".chiasmus")
      end

      def self.repo_config_path(repo_root : String = Dir.current) : String
        File.join(repo_config_dir(repo_root), "config.yml")
      end

      def self.ensure_repo_config_dir(repo_root : String = Dir.current) : String
        dir = repo_config_dir(repo_root)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        dir
      end

      def self.load_repo_config(repo_root : String = Dir.current) : RepoConfig
        ensure_repo_config_dir(repo_root)
        path = repo_config_path(repo_root)

        return DEFAULT_REPO_CONFIG.dup unless File.exists?(path)

        begin
          payload = File.read(path)
          return DEFAULT_REPO_CONFIG.dup if payload.strip.empty?

          RepoConfig.from_yaml(payload)
        rescue ex : YAML::ParseException | File::Error
          DEFAULT_REPO_CONFIG.dup
        end
      end

      def self.save_repo_config(config : RepoConfig, repo_root : String = Dir.current) : Nil
        ensure_repo_config_dir(repo_root)
        AtomicFile.write(repo_config_path(repo_root), config.to_yaml)
      end

      def self.ensure_repo_parity_config(
        vendor_src : String,
        target_src : Array(String),
        equivalences : Array(RepoParityConfig::RepoParityEquivalence) = [] of RepoParityConfig::RepoParityEquivalence,
        repo_root : String = Dir.current,
      ) : Nil
        config = load_repo_config(repo_root)
        parity = config.parity || RepoParityConfig.new

        parity.vendor_src ||= vendor_src
        parity.target_src ||= target_src.dup
        if (parity.equivalences.nil? || parity.equivalences.try(&.empty?)) && !equivalences.empty?
          parity.equivalences = equivalences.dup
        end

        config.parity = parity
        save_repo_config(config, repo_root)
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
