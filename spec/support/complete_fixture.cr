require "../spec_helper"

def chiasmus_complete_cli_binary : String
  File.join(chiasmus_cli_cache_dir, "chiasmus-complete-cli-test")
end

def chiasmus_parity_skill_dir : String
  candidates = [] of String
  env_dir = ENV["CHIASMUS_PARITY_SKILL_DIR"]?
  home = ENV["HOME"]? || raise "HOME is not set"
  candidates << env_dir.not_nil! if env_dir && !env_dir.empty?
  candidates << File.join(home, ".agents", "skills", "crystal_forge", "skills", "cross-language-crystal-parity")
  candidates << File.join(home, ".agents", "skills", "cross-language-crystal-parity")

  candidates.each do |dir|
    return dir if File.directory?(dir) && File.exists?(File.join(dir, "scripts", "plan_with_chiasmus.sh"))
  end

  raise "Unable to locate installed cross-language-crystal-parity skill; set CHIASMUS_PARITY_SKILL_DIR"
end

def chiasmus_parity_skill_script(name : String) : String
  script = File.join(chiasmus_parity_skill_dir, "scripts", name)
  raise "Missing parity skill script: #{script}" unless File.exists?(script)

  script
end

def chiasmus_complete_cli_sources : Array(String)
  [
    File.join(Dir.current, "src", "chiasmus_complete.cr"),
    File.join(Dir.current, "src", "chiasmus", "complete.cr"),
    File.join(Dir.current, "src", "chiasmus", "parity.cr"),
    File.join(Dir.current, "shard.yml"),
  ]
end

def chiasmus_complete_cli_binary_current?(binary : String) : Bool
  return false unless File.exists?(binary)

  binary_mtime = File.info(binary).modification_time
  chiasmus_complete_cli_sources.none? { |path| File.info(path).modification_time > binary_mtime }
rescue
  false
end

def build_chiasmus_complete_cli : String
  binary = chiasmus_complete_cli_binary
  return binary if chiasmus_complete_cli_binary_current?(binary)

  CHIASMUS_CLI_BUILD_MUTEX.synchronize do
    return binary if chiasmus_complete_cli_binary_current?(binary)

    Dir.mkdir_p(File.dirname(binary))
    result = Process.run(
      "crystal",
      ["build", "src/chiasmus_complete.cr", "-o", binary],
      env: chiasmus_cli_env,
      error: STDERR
    )
    raise "Failed to build chiasmus-complete CLI test binary: #{result.exit_code}" unless result.success?
  end

  binary
end

def chiasmus_complete_repo_bundle_dir : String
  File.join(chiasmus_cli_cache_dir, "chiasmus-complete-repo-bundle")
end

def chiasmus_complete_repo_bundle_current?(dir : String) : Bool
  required = [
    File.join(dir, "source_facts.pl"),
    File.join(dir, "parity.tsv"),
    File.join(dir, "completion_status.tsv"),
    File.join(dir, "completion_incomplete.tsv"),
  ]
  return false unless required.all? { |path| File.exists?(path) }

  bundle_mtime = required.map { |path| File.info(path).modification_time }.min
  inputs = [
    chiasmus_parity_skill_script("plan_with_chiasmus.sh"),
    File.join(Dir.current, "src", "chiasmus", "complete.cr"),
    File.join(Dir.current, "src", "chiasmus", "parity.cr"),
  ]

  inputs.none? { |path| File.info(path).modification_time > bundle_mtime }
end

def build_chiasmus_complete_repo_bundle : String
  dir = chiasmus_complete_repo_bundle_dir
  return dir if chiasmus_complete_repo_bundle_current?(dir)

  CHIASMUS_CLI_BUILD_MUTEX.synchronize do
    return dir if chiasmus_complete_repo_bundle_current?(dir)

    FileUtils.rm_rf(dir)
    Dir.mkdir_p(dir)

    script = chiasmus_parity_skill_script("plan_with_chiasmus.sh")
    result = Process.run(
      "bash",
      [script, Dir.current, "vendor/chiasmus", "typescript", "src", dir],
      env: {
        "CRYSTAL_CACHE_DIR"     => chiasmus_cli_cache_dir,
        "PORT_PARSER"           => "regex",
        "PORT_CRYSTAL_DIRS"     => "src:spec",
        "PORT_FACTS_CACHE_DIR"  => File.join(dir, "facts_cache"),
        "CHIASMUS_COMPLETE_BIN" => build_chiasmus_complete_cli,
      },
      output: STDOUT,
      error: STDERR,
    )

    raise "Failed to build complete repo bundle fixture: #{result.exit_code}" unless result.success?
  end

  dir
end
