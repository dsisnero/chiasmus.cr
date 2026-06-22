require "../src/chiasmus/graph/parallel_io"
require "../src/chiasmus/graph/extractor"
require "../src/chiasmus/graph/cache"
require "../src/chiasmus/discovery"
require "../src/chiasmus/mcp_server/tools/search"
require "file_utils"

class Chiasmus::MCPServer::Tools::SearchTool
  def read_search_files_for_benchmark(files : Array(String), max_concurrent : Int32)
    read_search_files(files, max_concurrent) { |path| File.read(path) }
  end
end

module ConcurrencyPerf
  extend self

  RELEASE_BUILD = {{ flag?(:release) }}
  PREVIEW_MT_BUILD = {{ flag?(:preview_mt) }}
  EXECUTION_CONTEXT_BUILD = {{ flag?(:execution_context) }}
  FILE_COUNT = env_int("CHIASMUS_BENCH_FILE_COUNT", 40)
  METHOD_COUNT = env_int("CHIASMUS_BENCH_METHOD_COUNT", 20)
  RUNS = env_int("CHIASMUS_BENCH_RUNS", 3)
  SECTIONS = (ENV["CHIASMUS_BENCH_SECTIONS"]? || "file-io,search-prep,discover,extract,async-cache").split(',').map(&.strip)

  record Measurement,
    label : String,
    avg_ms : Float64,
    cold_ms : Float64

  def run
    ensure_release_build!
    tmpdir = File.join(Dir.tempdir, "chiasmus-concurrency-bench-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(tmpdir)

    begin
      paths = build_fixture_repo(tmpdir)
      file_tuples = paths.map { |path| {path, File.read(path)} }

      puts "# Concurrency Benchmark"
      puts "files=#{paths.size} methods_per_file=#{METHOD_COUNT} cpus=#{System.cpu_count}"
      puts "sections=#{SECTIONS.join(",")}"
      puts "release=#{RELEASE_BUILD} preview_mt=#{PREVIEW_MT_BUILD} execution_context=#{EXECUTION_CONTEXT_BUILD}"
      puts

      results = [] of Measurement
      results.concat(benchmark_file_reads(paths)) if section_enabled?("file-io")
      results.concat(benchmark_search_prep(paths)) if section_enabled?("search-prep")
      results.concat(benchmark_discovery(file_tuples)) if section_enabled?("discover") && discovery_benchmark_enabled?
      results.concat(benchmark_extract_graph(paths)) if section_enabled?("extract")
      results.concat(benchmark_async_cache(paths)) if section_enabled?("async-cache")

      puts
      puts "## Summary"
      results.each do |result|
        printf "%-42s avg=%8.2fms cold=%8.2fms\n", result.label, result.avg_ms, result.cold_ms
      end
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  private def benchmark_file_reads(paths : Array(String)) : Array(Measurement)
    puts "## File I/O"
    results = [
      measure("read sequential") { sequential_read(paths) },
      measure("read concurrent x1") { Chiasmus::Graph::FileIO.read_source_files_or_raise(paths, 1) },
      measure("read concurrent x#{worker_count(paths)}") { Chiasmus::Graph::FileIO.read_source_files_or_raise(paths, worker_count(paths)) },
    ]
    results.concat(benchmark_file_reads_with_execution_context(paths))
    results
  end

  private def benchmark_search_prep(paths : Array(String)) : Array(Measurement)
    puts
    puts "## Search Prep"
    tool = Chiasmus::MCPServer::Tools::SearchTool.new
    [
      measure("search prep x1") { tool.read_search_files_for_benchmark(paths, 1) },
      measure("search prep x#{worker_count(paths)}") { tool.read_search_files_for_benchmark(paths, worker_count(paths)) },
    ]
  end

  private def benchmark_discovery(file_tuples : Array(Tuple(String, String))) : Array(Measurement)
    puts
    puts "## Discovery"
    pipeline_1 = discovery_pipeline(1)
    pipeline_n = discovery_pipeline(worker_count(file_tuples.map(&.[0])))

    [
      measure("discover sequential baseline") { discover_sequential(file_tuples) },
      measure("discover current impl (cfg x1)") { pipeline_1.discover_files(file_tuples) },
      measure("discover current impl (cfg x#{worker_count(file_tuples.map(&.[0]))})") { pipeline_n.discover_files(file_tuples) },
    ]
  end

  private def benchmark_async_cache(paths : Array(String)) : Array(Measurement)
    puts
    puts "## Async Cache"
    cache_dir = File.join(Dir.tempdir, "chiasmus-concurrency-cache-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(cache_dir)
    sources = paths.map { |path| Chiasmus::Graph::SourceFile.new(path: path, content: File.read(path)) }

    begin
      [
        measure("extract_graph return (async cache)") do
          Chiasmus::Graph::Extractor.extract_graph(sources, cache_dir: cache_dir)
        end,
        measure("cache flush after extract_graph") do
          Chiasmus::Graph::GraphCache.flush_async_writes
        end,
      ]
    ensure
      FileUtils.rm_rf(cache_dir)
    end
  end

  private def benchmark_extract_graph(paths : Array(String)) : Array(Measurement)
    puts
    puts "## Extract Graph"
    sources = paths.map { |path| Chiasmus::Graph::SourceFile.new(path: path, content: File.read(path)) }
    n = worker_count(paths)

    results = [
      measure("extract graph x1") { Chiasmus::Graph::Extractor.extract_graph(sources, max_concurrent: 1) },
      measure("extract graph x#{n}") { Chiasmus::Graph::Extractor.extract_graph(sources, max_concurrent: n) },
      measure("extract graph default") { Chiasmus::Graph::Extractor.extract_graph(sources) },
    ]
    results.concat(benchmark_extract_graph_with_execution_context(sources, n))
    results
  end

  private def sequential_read(paths : Array(String)) : Array(Chiasmus::Graph::SourceFile)
    paths.map do |path|
      Chiasmus::Graph::SourceFile.new(path: path, content: File.read(path))
    end
  end

  private def discovery_pipeline(max_concurrent : Int32) : Chiasmus::Discovery::Pipeline
    extractors = [Chiasmus::Discovery::CrystalExtractor.new] of Chiasmus::Discovery::LanguageExtractor
    Chiasmus::Discovery::Pipeline.new(extractors, max_concurrent)
  end

  private def discover_sequential(files : Array(Tuple(String, String))) : Chiasmus::Discovery::Result
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    language = Chiasmus::Discovery::GrammarLoader.load_language(extractor.grammar_language)
    raise "crystal grammar not available for benchmark" unless language

    all_items = [] of Chiasmus::Discovery::Item
    files.each do |file_path, content|
      parser = TreeSitter::Parser.new(language: language)
      tree = parser.parse(nil, content)
      all_items.concat(extractor.extract(tree.root_node, content, file_path))
    rescue
    end

    seen = Set(String).new
    Chiasmus::Discovery::Result.new(
      items: all_items.select { |item| seen.add?(item.id) },
      parser_mode: "tree-sitter"
    )
  end

  private def build_fixture_repo(tmpdir : String) : Array(String)
    paths = [] of String

    FILE_COUNT.times do |i|
      path = File.join(tmpdir, "f#{i}.cr")
      File.write(path, crystal_fixture(i))
      paths << path
    end

    paths
  end

  private def crystal_fixture(index : Int32) : String
    String.build do |io|
      io << "module Bench" << index << "\n"
      io << "  class Worker" << index << "\n"
      METHOD_COUNT.times do |m|
        io << "    def step_" << m << "(value)\n"
        io << "      value + " << m << "\n"
        io << "    end\n"
      end
      io << "  end\n"
      io << "end\n"
    end
  end

  private def measure(label : String, runs : Int32 = RUNS, &block) : Measurement
    print "  #{label}: "
    times = [] of Float64

    runs.times do |i|
      GC.collect
      elapsed = Time.measure { yield }
      times << elapsed.total_milliseconds
      print "." if i > 0
    end

    avg = times[1..].sum / (runs - 1)
    printf " avg=%0.2fms cold=%0.2fms\n", avg, times[0]
    Measurement.new(label: label, avg_ms: avg, cold_ms: times[0])
  end

  private def worker_count(paths : Array(String)) : Int32
    Math.max(2, Math.min(System.cpu_count, paths.size))
  end

  private def ensure_release_build! : Nil
    return if RELEASE_BUILD
    raise "Run benchmarks with --release. Set CHIASMUS_ALLOW_DEBUG_BENCH=1 only if you intentionally want non-release numbers." if ENV["CHIASMUS_ALLOW_DEBUG_BENCH"]? != "1"
  end

  private def env_int(name : String, fallback : Int32) : Int32
    ENV[name]?.try(&.to_i32?) || fallback
  end

  private def section_enabled?(name : String) : Bool
    SECTIONS.includes?(name)
  end

  private def discovery_benchmark_enabled? : Bool
    return true unless EXECUTION_CONTEXT_BUILD
    return true if ENV["CHIASMUS_BENCH_ALLOW_CTX_DISCOVERY"]? == "1"

    puts
    puts "## Discovery"
    puts "  skipped: discovery is currently unstable under -Dpreview_mt -Dexecution_context on larger fixtures"
    false
  end

  {% if flag?(:execution_context) %}
    private def benchmark_file_reads_with_execution_context(paths : Array(String)) : Array(Measurement)
      n = worker_count(paths)
      [
        measure_in_parallel_default_context("read concurrent x#{n} ctx default(1)", 1) do
          Chiasmus::Graph::FileIO.read_source_files_or_raise(paths, n)
        end,
        measure_in_parallel_default_context("read concurrent x#{n} ctx parallel(#{n})", n) do
          Chiasmus::Graph::FileIO.read_source_files_or_raise(paths, n)
        end,
      ]
    end

    private def benchmark_extract_graph_with_execution_context(
      sources : Array(Chiasmus::Graph::SourceFile),
      worker_count : Int32
    ) : Array(Measurement)
      [
        measure("extract graph x#{worker_count} parallel_cpu") do
          Chiasmus::Graph::Extractor.extract_graph(sources, max_concurrent: worker_count, parallel_cpu: true)
        end,
      ]
    end

    private def measure_in_parallel_default_context(label : String, parallelism : Int32, &block) : Measurement
      Fiber::ExecutionContext.default.resize(parallelism)
      measure(label) { yield }
    ensure
      Fiber::ExecutionContext.default.resize(1)
    end
  {% else %}
    private def benchmark_file_reads_with_execution_context(paths : Array(String)) : Array(Measurement)
      [] of Measurement
    end

    private def benchmark_extract_graph_with_execution_context(
      sources : Array(Chiasmus::Graph::SourceFile),
      worker_count : Int32
    ) : Array(Measurement)
      [] of Measurement
    end
  {% end %}
end

ConcurrencyPerf.run
