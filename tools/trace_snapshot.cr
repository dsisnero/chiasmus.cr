require "../src/chiasmus"
require "tracing"

# Set up tracing subscriber with JSON output to stderr
registry = Tracing::Registry.new
layer = Tracing::FmtLayer.new(io: STDERR).json.with_level(false).with_target(true)
subscriber = Tracing::Layered(Tracing::Registry).new(registry, layer)
Tracing::Core::Dispatch.global_default = Tracing::Core::Dispatch.new(subscriber)

# Enable CPU-parallel extraction and per-file caching. Crystal extraction
# already honors its requested bounded concurrency by default.
ENV["CHIASMUS_GRAPH_PARALLEL"] = "1"

# Files to analyze
files = Dir.glob("lib/crig/src/**/*.cr")
  .reject { |f| f.starts_with?("._") }
  .sort
  .map { |f| File.expand_path(f) }

cache_dir = "/tmp/chiasmus-trace-cache"
repo_key = "trace-test"
save_snapshot = "trace-snap-cached-#{Time.utc.to_unix_ms}"

# Use existing cache from previous run
# Chiasmus::Graph::GraphCache.clear_repo_cache(cache_dir, repo_key)

Tracing.info("trace.start",
  files: files.size,
  snapshot: save_snapshot,
  cache_dir: cache_dir,
  parallel: true,
)

request = Chiasmus::Graph::AnalysisRequest.new(
  analysis: Chiasmus::Graph::AnalysisType::Summary,
)

result = Chiasmus::Graph::Analyses.run_analysis(
  files,
  request,
  cache_dir: cache_dir,
  snapshot_cache_dir: cache_dir,
  repo_key: repo_key,
  max_bytes: 64 * 1024 * 1024,
  save_snapshot: save_snapshot,
)

# Flush pending async writes
Chiasmus::Graph::GraphCache.flush_async_writes

Tracing.info("trace.complete")

# Output the analysis result to stdout
puts "RESULT: #{result.result.to_json}"
