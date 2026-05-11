require "option_parser"
require "json"
require "crig"
require "./graph/types"
require "./graph/analyses"
require "./graph/extractor"
require "./graph/facts"
require "./formalize/engine"
require "./skills/library"
require "./llm/types"

module Chiasmus
  module AgentCLI
    VERSION = "0.1.0"

    struct Options
      getter mode : Symbol
      getter question : String?
      getter code_files : Array(String)
      getter provider : String
      getter model : String?
      getter api_key : String?
      getter base_url : String?
      getter? json : Bool
      getter? debug : Bool

      def initialize(
        @mode : Symbol = :ask,
        @question : String? = nil,
        @code_files : Array(String) = [] of String,
        @provider : String = "deepseek",
        @model : String? = nil,
        @api_key : String? = nil,
        @base_url : String? = nil,
        @json : Bool = false,
        @debug : Bool = false,
      )
      end
    end

    def self.parse(args : Array(String)) : Options
      opts = Options.new
      remaining = [] of String

      p = OptionParser.new do |op|
        op.banner = "Usage: chiasmus-agent [options] [command] [question...]"

        op.on("-c", "--code FILE", "Add code file for graph analysis") do |file|
          opts = opts_with(opts, code_files: opts.code_files + [file])
        end

        op.on("-p", "--provider NAME", "LLM provider (deepseek, openai, etc)") do |name|
          opts = opts_with(opts, provider: name)
        end

        op.on("-m", "--model MODEL", "LLM model name") do |model|
          opts = opts_with(opts, model: model)
        end

        op.on("-k", "--api-key KEY", "LLM API key") do |key|
          opts = opts_with(opts, api_key: key)
        end

        op.on("-u", "--base-url URL", "LLM API base URL") do |url|
          opts = opts_with(opts, base_url: url)
        end

        op.on("--json", "Output in JSON format") do
          opts = opts_with(opts, json: true)
        end

        op.on("--debug", "Enable debug output") do
          opts = opts_with(opts, debug: true)
        end

        op.on("-h", "--help", "Show help") do
          puts op
          raise OptionParser::Exception.new("help")
        end

        op.on("--version", "Show version") do
          puts "chiasmus-agent v#{VERSION}"
          raise OptionParser::Exception.new("version")
        end

        op.unknown_args do |before, after|
          remaining = before + after
        end
      end

      p.parse(args)

      if remaining.empty?
        return opts
      end

      case remaining[0]
      when "ask"
        if remaining.size < 2
          raise OptionParser::Exception.new("question required for 'ask' command")
        end
        question = remaining[1..].join(" ")
        opts_with(opts, mode: :ask, question: question)
      when "repl"
        opts_with(opts, mode: :repl, question: nil)
      else
        question = remaining.join(" ")
        opts_with(opts, mode: :ask, question: question)
      end
    end

    private def self.opts_with(base : Options, mode : Symbol? = nil, question : String? = nil, code_files : Array(String)? = nil, provider : String? = nil, model : String? = nil, api_key : String? = nil, base_url : String? = nil, json : Bool? = nil, debug : Bool? = nil) : Options
      Options.new(
        mode: mode.nil? ? base.mode : mode,
        question: question.nil? ? base.question : question,
        code_files: code_files.nil? ? base.code_files : code_files,
        provider: provider.nil? ? base.provider : provider,
        model: model.nil? ? base.model : model,
        api_key: api_key.nil? ? base.api_key : api_key,
        base_url: base_url.nil? ? base.base_url : base_url,
        json: json.nil? ? base.@json : json,
        debug: debug.nil? ? base.@debug : debug,
      )
    end

    def self.question_to_graph_analysis(question : String) : Hash(Symbol, String)?
      lower = question.downcase.strip

      graph_relationship_analysis(lower) ||
        graph_path_analysis(lower) ||
        graph_keyword_analysis(lower)
    end

    private def self.graph_relationship_analysis(lower : String) : Hash(Symbol, String)?
      if lower =~ /^callers?\s+of\s+(\S+)/
        {:analysis => "callers", :target => $1}
      elsif lower =~ /^callees?\s+of\s+(\S+)/
        {:analysis => "callees", :target => $1}
      elsif lower =~ /^(?:can\s+)?(\w[\w\d]*)\s+reach\s+(\w[\w\d]*)\??/
        {:analysis => "reachability", :from => $1, :to => $2}
      elsif lower =~ /^is\s+(\w[\w\d]*)\s+reachable\s+from\s+(\w[\w\d]*)/
        {:analysis => "reachability", :from => $2, :to => $1}
      end
    end

    private def self.graph_path_analysis(lower : String) : Hash(Symbol, String)?
      if lower =~ /path\s+from\s+(\S+)\s+to\s+(\S+)/
        {:analysis => "path", :from => $1, :to => $2}
      elsif lower =~ /impact\s+of\s+(\S+)/
        {:analysis => "impact", :target => $1}
      elsif lower =~ /affected\s+if\s+(\S+)\s+changes/
        {:analysis => "impact", :target => $1}
      end
    end

    private def self.graph_keyword_analysis(lower : String) : Hash(Symbol, String)?
      if lower =~ /(?:find\s+)?dead\s*code/
        {:analysis => "dead-code"}
      elsif lower =~ /(?:find\s+)?cycles?/
        {:analysis => "cycles"}
      elsif lower =~ /^(?:show\s+)?summary|summarize/
        {:analysis => "summary"}
      elsif lower =~ /(?:prolog\s+)?facts?/
        {:analysis => "facts"}
      end
    end

    def self.run_graph_analysis(code_files : Array(String), question : String) : String
      if code_files.empty?
        return graph_error_response("No code files provided. Use --code to specify files.")
      end

      analysis_params = question_to_graph_analysis(question)

      unless analysis_params
        return graph_error_response("Could not understand graph question: '#{question}'. Try 'callers of X', 'callees of X', 'can X reach Y?', 'dead code', 'cycles', 'path from X to Y', 'impact of X', 'summary', or 'facts'.")
      end

      analysis_type = graph_analysis_type(analysis_params[:analysis])
      return graph_error_response("Unknown analysis type: #{analysis_params[:analysis]}") unless analysis_type

      source_files = code_files.map do |path|
        Graph::SourceFile.new(path: path, content: File.read(path))
      end

      graph = Graph::Extractor.extract_graph(source_files)

      result = Graph::Analyses.run_analysis_from_graph(
        graph,
        Graph::AnalysisRequest.new(
          analysis: analysis_type,
          target: analysis_params[:target]?,
          from: analysis_params[:from]?,
          to: analysis_params[:to]?
        )
      )

      build_graph_response(analysis_params, result)
    end

    private def self.graph_error_response(message : String) : String
      JSON.build do |json|
        json.object do
          json.field "status", "error"
          json.field "error", message
        end
      end
    end

    private def self.graph_analysis_type(name : String) : Graph::AnalysisType?
      case name
      when "callers"      then Graph::AnalysisType::Callers
      when "callees"      then Graph::AnalysisType::Callees
      when "reachability" then Graph::AnalysisType::Reachability
      when "dead-code"    then Graph::AnalysisType::DeadCode
      when "cycles"       then Graph::AnalysisType::Cycles
      when "path"         then Graph::AnalysisType::Path
      when "impact"       then Graph::AnalysisType::Impact
      when "summary"      then Graph::AnalysisType::Summary
      when "facts"        then Graph::AnalysisType::Facts
      end
    end

    private def self.build_graph_response(
      analysis_params : Hash(Symbol, String),
      result : Graph::AnalysisResult,
    ) : String
      JSON.build do |json|
        json.object do
          json.field "status", "success"
          json.field "analysis", analysis_params[:analysis]

          if target = analysis_params[:target]?
            json.field "target", target
          end
          if from = analysis_params[:from]?
            json.field "from", from
          end
          if to = analysis_params[:to]?
            json.field "to", to
          end

          case payload = result.result
          when Hash(String, Int32)
            json.field "result" do
              json.object do
                payload.each { |k, v| json.field k, v }
              end
            end
          when Array(String)
            json.field "result", payload
          when String
            json.field "result", payload
          when Hash(String, Bool)
            json.field "result" do
              json.object do
                payload.each { |k, v| json.field k, v }
              end
            end
          when Hash(String, String)
            json.field "result" do
              json.object do
                payload.each { |k, v| json.field k, v }
              end
            end
          else
            json.field "result", payload.to_s
          end
        end
      end
    end

    def self.format_output(json_str : String, json : Bool = false) : String
      if json
        return json_str
      end

      parsed = JSON.parse(json_str)

      if parsed["status"] == "error"
        return "Error: #{parsed["error"]}"
      end

      if parsed["solver"]?
        format_solve_output(parsed)
      elsif parsed["analysis"]?
        format_graph_output(parsed)
      else
        json_str
      end
    end

    private def self.format_solve_output(parsed : JSON::Any) : String
      String.build do |io|
        io << "Formal Verification Result\n"
        io << "  Solver: #{parsed["solver"]}\n"
        io << "  Template: #{parsed["template"]}\n"

        if parsed["satisfiable"]?
          if parsed["satisfiable"].as_bool
            io << "  Status: Satisfiable\n"
            if model = parsed["model"]?
              io << "  Model: #{model}\n"
            end
          else
            io << "  Status: Unsatisfiable\n"
            if unsat = parsed["unsat_core"]?
              unless unsat.as_a.empty?
                io << "  Unsat core: #{unsat}\n"
              end
            end
          end
        elsif parsed["success"]?
          io << "  Status: Success\n"
          if answers = parsed["answers"]?
            io << "  Answers: #{answers.as_a.size}\n"
            answers.as_a.each_with_index do |answer, index|
              io << "    #{index + 1}. #{answer}\n"
            end
          end
        elsif parsed["error"]?
          io << "  Error: #{parsed["error"]}\n"
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.format_graph_output(parsed : JSON::Any) : String
      analysis = parsed["analysis"].as_s

      case analysis
      when "summary"
        r = parsed["result"]
        String.build do |io|
          io << "Summary\n"
          io << "  files: #{r["files"]}\n"
          io << "  functions: #{r["functions"]}\n"
          io << "  classes: #{r["classes"]}\n"
          io << "  callEdges: #{r["callEdges"]}\n"
          io << "  imports: #{r["imports"]}\n"
          io << "  exports: #{r["exports"]}\n"
        end
      when "callers"
        target = parsed["target"]?.try(&.as_s) || "?"
        items = parsed["result"].as_a
        String.build do |io|
          io << "Callers of '#{target}':\n"
          items.each { |i| io << "  - #{i}\n" }
        end
      when "callees"
        target = parsed["target"]?.try(&.as_s) || "?"
        items = parsed["result"].as_a
        String.build do |io|
          io << "Callees of '#{target}':\n"
          items.each { |i| io << "  - #{i}\n" }
        end
      when "dead-code"
        items = parsed["result"].as_a
        String.build do |io|
          io << "Dead Code:\n"
          if items.empty?
            io << "  (none found)\n"
          else
            items.each { |i| io << "  - #{i}\n" }
          end
        end
      when "cycles"
        items = parsed["result"].as_a
        String.build do |io|
          io << "Cycles:\n"
          if items.empty?
            io << "  (none found)\n"
          else
            items.each { |i| io << "  - #{i}\n" }
          end
        end
      when "reachability"
        from = parsed["from"]?.try(&.as_s) || "?"
        to = parsed["to"]?.try(&.as_s) || "?"
        reachable = parsed["result"]["reachable"].as_bool
        "Reachability: '#{from}' -> '#{to}' is #{reachable ? "reachable" : "NOT reachable"}"
      when "path"
        paths = parsed["result"]["paths"].as_a
        String.build do |io|
          io << "Paths:\n"
          paths.each_with_index do |path, i|
            io << "  #{i + 1}. #{path.as_a.join(" -> ")}\n"
          end
        end
      when "impact"
        target = parsed["target"]?.try(&.as_s) || "?"
        items = parsed["result"].as_a
        String.build do |io|
          io << "Impact analysis for '#{target}':\n"
          items.each { |i| io << "  - #{i}\n" }
        end
      when "facts"
        prolog = parsed["result"].as_s
        String.build do |io|
          io << "Prolog Facts:\n"
          prolog.each_line do |line|
            io << "  #{line}\n"
          end
        end
      else
        parsed["result"].to_s
      end
    end

    def self.build_agent(opts : Options)
      config = LLM::SimpleConfig.new(
        provider: opts.provider,
        api_key: opts.api_key,
        base_url: opts.base_url,
        model: opts.model || Crig::Providers::DeepSeek::DEEPSEEK_CHAT
      )

      LLM::Builders.deepseek(api_key: opts.api_key, base_url: opts.base_url)
        .build
        .agent(config.model)
        .preamble(config.preamble)
        .build
    end

    def self.run_formal_solve(question : String, agent, debug : Bool = false) : String
      library = Skills::Library.create(Utils::Config.chiasmus_home)
      engine = Formalize::Engine.new(library, agent)

      solve_result = engine.solve(question)

      JSON.build do |json|
        json.object do
          json.field "status", "success"
          json.field "solver", solve_result.result.class.name.split("::").last.gsub("Result", "").downcase
          json.field "template", solve_result.template_used || "unknown"
          json.field "converged", solve_result.converged
          json.field "rounds", solve_result.rounds

          case result = solve_result.result
          when Solvers::SatResult
            json.field "satisfiable", true
            json.field "model", result.model
          when Solvers::UnsatResult
            json.field "satisfiable", false
            if core = result.unsat_core
              json.field "unsat_core", core
            end
          when Solvers::UnknownResult
            json.field "satisfiable", false
            json.field "status_detail", "unknown"
          when Solvers::SuccessResult
            json.field "success", true
            json.field "answers", result.answers.map(&.bindings)
          when Solvers::ErrorResult
            json.field "error", result.error
            json.field "success", false
          end

          if debug
            json.field "debug" do
              json.object do
                json.field "rounds", solve_result.rounds
                json.field "converged", solve_result.converged
                json.field "template_used", solve_result.template_used
              end
            end
          end
        end
      end
    end

    def self.run_repl(agent, opts : Options)
      puts "=== Chiasmus Agent REPL ==="
      puts "Type a question to analyze or solve formally."
      puts "Use --code loaded files for graph analysis, or ask plain questions for formal verification."
      puts "Type 'quit' or 'exit' to stop."
      puts "=========================="

      loop do
        print "> "
        input = gets.try(&.strip)
        break if input.nil?
        break if input.downcase.in?("quit", "exit")
        next if input.empty?

        begin
          if !opts.code_files.empty?
            graph_result = run_graph_analysis(opts.code_files, input)
            parsed = JSON.parse(graph_result)
            if parsed["status"] == "success" || parsed["analysis"]?
              puts format_output(graph_result, json: opts.json?)
            else
              puts "(Graph analysis not applicable, trying formal solver...)"
              result = run_formal_solve(input, agent, opts.debug?)
              puts format_output(result, json: opts.json?)
            end
          else
            result = run_formal_solve(input, agent, opts.debug?)
            puts format_output(result, json: opts.json?)
          end
        rescue ex
          puts "Error: #{ex.message}"
          puts ex.backtrace.first(3).join("\n") if opts.debug?
        end

        puts
      end

      puts "Goodbye!"
    end
  end
end
