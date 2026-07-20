require "spec"
require "tracing"
require "../src/chiasmus"
require "../src/benchmark/**"

module ChiasmusSpecTracing
  class LockedWriter < IO
    @path : String
    @mutex : Mutex

    def initialize(@path : String)
      @mutex = Mutex.new
    end

    def write(slice : Bytes) : Nil
      @mutex.synchronize do
        File.open(@path, "a") do |io|
          io.write(slice)
          io.flush
        end
      end
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("LockedWriter is write-only")
    end

    def close : Nil
      # no-op: writes open and close the file per call
    end
  end

  @@trace_io : LockedWriter? = nil
  @@installed = false

  def self.install! : Nil
    return if @@installed

    trace_path = ENV["CHIASMUS_TRACE_FILE"]?
    return unless trace_path

    trace_layer = build_trace_layer(trace_path)
    filter = Tracing::EnvFilter.from_env

    if trace_layer
      Tracing::Registry.default.with(trace_layer).with(filter).init
    end

    @@installed = true
    at_exit { shutdown }
  end

  private def self.build_trace_layer(path : String?) : Tracing::FmtLayer?
    return nil unless path

    Dir.mkdir_p(File.dirname(path))
    @@trace_io = LockedWriter.new(path)

    layer = Tracing::FmtLayer.new(@@trace_io.not_nil!)
      .with_target(true)
      .with_ansi(false)
      .with_span_events(parse_span_events(ENV["CHIASMUS_TRACE_SPAN_EVENTS"]?))

    case (ENV["CHIASMUS_TRACE_FORMAT"]? || "json").downcase
    when "pretty"
      layer.pretty
    when "compact"
      layer.compact
    when "text", "default"
      layer
    else
      layer.json
    end
  end

  private def self.parse_span_events(raw : String?) : Tracing::FmtSpan
    return Tracing::FmtSpan::FULL unless raw

    value = raw.downcase.strip
    return Tracing::FmtSpan::FULL if value.empty? || value == "full"
    return Tracing::FmtSpan::ACTIVE if value == "active"
    return Tracing::FmtSpan::NONE if value == "none"

    events = Tracing::FmtSpan::NONE
    value.split(',').each do |part|
      case part.strip
      when "new"
        events |= Tracing::FmtSpan::NEW
      when "enter"
        events |= Tracing::FmtSpan::ENTER
      when "exit"
        events |= Tracing::FmtSpan::EXIT
      when "close"
        events |= Tracing::FmtSpan::CLOSE
      end
    end

    events.none? ? Tracing::FmtSpan::FULL : events
  end

  def self.shutdown : Nil
    @@trace_io.try(&.close)
    @@trace_io = nil
  end
end

ChiasmusSpecTracing.install!

def chiasmus_cli_command(cli_args : Array(String) = [] of String) : {String, Array(String)}
  build_chiasmus_cli
  {chiasmus_cli_binary, cli_args}
end

def chiasmus_cli_env : Hash(String, String)
  {"CRYSTAL_CACHE_DIR" => chiasmus_cli_cache_dir}
end

CHIASMUS_CLI_BUILD_MUTEX = Mutex.new

def chiasmus_cli_cache_dir : String
  ENV["CRYSTAL_CACHE_DIR"]? || File.join(Dir.tempdir, "chiasmus-cli-cache")
end

def chiasmus_cli_binary : String
  File.join(chiasmus_cli_cache_dir, "chiasmus-cli-test")
end

def chiasmus_cli_sources : Array(String)
  [
    File.join(Dir.current, "src", "chiasmus.cr"),
    File.join(Dir.current, "src", "chiasmus_cli.cr"),
    File.join(Dir.current, "shard.yml"),
  ]
end

def chiasmus_cli_binary_current?(binary : String) : Bool
  return false unless File.exists?(binary)

  binary_mtime = File.info(binary).modification_time
  return false if chiasmus_cli_sources.any? { |path| File.info(path).modification_time > binary_mtime }

  output = IO::Memory.new
  result = Process.run(binary, ["--version"], env: chiasmus_cli_env, output: output, error: output)
  result.success? && output.to_s.includes?(Chiasmus::VERSION)
rescue
  false
end

def build_chiasmus_cli
  binary = chiasmus_cli_binary
  return if chiasmus_cli_binary_current?(binary)
  CHIASMUS_CLI_BUILD_MUTEX.synchronize do
    return if chiasmus_cli_binary_current?(binary)
    Dir.mkdir_p(File.dirname(binary))
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
