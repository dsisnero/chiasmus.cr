require "spec"
require "../src/chiasmus"
require "../src/benchmark/**"

def chiasmus_cli_command(cli_args : Array(String) = [] of String) : {String, Array(String)}
  build_chiasmus_cli
  {chiasmus_cli_binary, cli_args}
end

def chiasmus_cli_env : Hash(String, String)
  {"CRYSTAL_CACHE_DIR" => File.join(Dir.current, ".crystal-cache")}
end

CHIASMUS_CLI_BUILD_MUTEX = Mutex.new

def chiasmus_cli_binary : String
  File.join(Dir.current, ".crystal-cache", "chiasmus-cli-test")
end

def build_chiasmus_cli
  binary = chiasmus_cli_binary
  return if File.exists?(binary)
  CHIASMUS_CLI_BUILD_MUTEX.synchronize do
    return if File.exists?(binary)
    result = Process.run(
      "crystal", ["build", "src/chiasmus_cli.cr", "-o", binary],
      env: chiasmus_cli_env,
      error: STDERR
    )
    unless result.success?
      raise "Failed to build chiasmus CLI test binary: #{result.exit_code}"
    end
  end
end

# Helper to temporarily set environment variables for tests
def with_env(env_vars : Hash(String, String?), &)
  original_values = {} of String => String?

  env_vars.each do |key, value|
    original_values[key] = ENV[key]?
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  begin
    yield
  ensure
    original_values.each do |key, original_value|
      if original_value.nil?
        ENV.delete(key)
      else
        ENV[key] = original_value
      end
    end
  end
end
