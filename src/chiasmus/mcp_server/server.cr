# Main MCP server implementation for chiasmus
require "json"
require "mcp"
require "mcp/src/mcp/runner"
require "crig"
require "./tools/verify"
require "./tools/skills"
require "./tools/formalize"
require "./tools/solve"
require "./tools/learn"
require "./tools/lint"
require "./tools/graph"
require "./tools/map"
require "./tools/search"
require "./tools/craft"
require "./tools/review"
require "./tools/crig"

module Chiasmus
  module MCPServer
    RUNTIME_LOCK = Mutex.new

    record AsyncCallResult(T),
      value : T? = nil,
      error : String? = nil

    class ToolDispatcher
      DEFAULT_MAX_CONCURRENT = {System.cpu_count, 1}.max

      @slots : Channel(Bool)

      def initialize(max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT)
        @slots = Channel(Bool).new({max_concurrent, 1}.max)
      end

      def dispatch(&block : -> T) : Channel(T) forall T
        response = Channel(T).new(1)

        spawn do
          @slots.send(true)
          begin
            response.send(block.call)
          ensure
            @slots.receive?
            response.close
          end
        end

        response
      end
    end

    abstract class BaseServer
      abstract def skill_library : Skills::Library
      abstract def skill_learner : Skills::Learner?
      abstract def formalize(problem : String) : Formalize::FormalizeResult?
      abstract def formalize_async(problem : String) : Channel(AsyncCallResult(Formalize::FormalizeResult))
      abstract def solve(problem : String, max_rounds : Int32 = 5) : Formalize::SolveResult?
      abstract def solve_async(problem : String, max_rounds : Int32 = 5) : Channel(AsyncCallResult(Formalize::SolveResult))
      abstract def run
      abstract def run_streamable(port : Int32 = 8899)
      abstract def healthcheck : NamedTuple(success: Bool, tools: Int32?, version: String?, error: String?)
    end

    @@current_server = nil.as(BaseServer?)

    def self.current_server : BaseServer?
      RUNTIME_LOCK.synchronize { @@current_server }
    end

    def self.current_server=(server : BaseServer?) : BaseServer?
      RUNTIME_LOCK.synchronize do
        @@current_server = server
      end
    end

    def self.current_skill_learner : Skills::Learner?
      RUNTIME_LOCK.synchronize do
        @@current_server.try(&.skill_learner)
      end
    end

    # Main server class that orchestrates all chiasmus functionality
    # Generic over model type M to support different LLM providers
    class Server(M) < BaseServer
      @@before_formalize_async_result_send_hook : Proc(Nil)? = nil
      @@before_solve_async_result_send_hook : Proc(Nil)? = nil

      @formalization_engine : Formalize::Engine(M)?
      @skill_learner : Skills::Learner?
      @tool_dispatcher : ToolDispatcher
      @tool_handlers : Hash(String, Proc(Hash(String, JSON::Any), MCP::Protocol::CallToolResult))

      # Create a server instance with a specific agent
      def self.with_agent(agent : Crig::Agent(M)) forall M
        server = Server(M).new
        server.with_agent(agent)
        MCPServer.current_server = server
        server
      end

      # Keep the builder-first Crig flow available for local callers and specs.
      def self.with_agent_builder(builder : Crig::AgentBuilder(M)) forall M
        with_agent(builder.build)
      end

      getter skill_library : Skills::Library
      getter skill_learner : Skills::Learner?

      def initialize
        @config = Utils::Config.load
        @skill_library = Skills::Library.create(self.class.chiasmus_home)
        @skill_learner = nil
        @formalization_engine = nil
        @tool_dispatcher = ToolDispatcher.new
        @tool_handlers = {} of String => Proc(Hash(String, JSON::Any), MCP::Protocol::CallToolResult)
      end

      # Set the agent for formalization engine
      def with_agent(agent : Crig::Agent(M)) : self
        @formalization_engine = Formalize::Engine.new(@skill_library, agent)
        @skill_learner = Skills::Learner.new(@skill_library, build_skill_extractor(agent))
        self
      end

      def with_agent_builder(builder : Crig::AgentBuilder(M)) : self
        with_agent(builder.build)
      end

      def formalization_engine : Formalize::Engine(M)?
        @formalization_engine
      end

      def formalize(problem : String) : Formalize::FormalizeResult?
        @formalization_engine.try(&.formalize(problem))
      end

      def formalize_async(problem : String) : Channel(AsyncCallResult(Formalize::FormalizeResult))
        response = Channel(AsyncCallResult(Formalize::FormalizeResult)).new(1)

        spawn do
          result = if engine = @formalization_engine
                     engine_result = engine.formalize_async(problem).receive
                     AsyncCallResult(Formalize::FormalizeResult).new(
                       value: engine_result.try(&.value),
                       error: engine_result.try(&.error)
                     )
                   else
                     AsyncCallResult(Formalize::FormalizeResult).new(value: formalize(problem))
                   end

          @@before_formalize_async_result_send_hook.try(&.call)
          response.send(result)
        rescue ex
          response.send(AsyncCallResult(Formalize::FormalizeResult).new(error: ex.message || ex.class.name))
        ensure
          response.close
        end

        response
      end

      def solve(problem : String, max_rounds : Int32 = 5) : Formalize::SolveResult?
        @formalization_engine.try(&.solve(problem, max_rounds))
      end

      def solve_async(problem : String, max_rounds : Int32 = 5) : Channel(AsyncCallResult(Formalize::SolveResult))
        response = Channel(AsyncCallResult(Formalize::SolveResult)).new(1)

        spawn do
          result = if engine = @formalization_engine
                     engine_result = engine.solve_async(problem, max_rounds).receive
                     AsyncCallResult(Formalize::SolveResult).new(
                       value: engine_result.try(&.value),
                       error: engine_result.try(&.error)
                     )
                   else
                     AsyncCallResult(Formalize::SolveResult).new(value: solve(problem, max_rounds))
                   end

          @@before_solve_async_result_send_hook.try(&.call)
          response.send(result)
        rescue ex
          response.send(AsyncCallResult(Formalize::SolveResult).new(error: ex.message || ex.class.name))
        ensure
          response.close
        end

        response
      end

      def self.set_before_formalize_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_formalize_async_result_send_hook = block
      end

      def self.clear_before_formalize_async_result_send_hook_for_test : Nil
        @@before_formalize_async_result_send_hook = nil
      end

      def self.set_before_solve_async_result_send_hook_for_test(&block : ->) : Nil
        @@before_solve_async_result_send_hook = block
      end

      def self.clear_before_solve_async_result_send_hook_for_test : Nil
        @@before_solve_async_result_send_hook = nil
      end

      # Start the MCP server on stdio
      def run
        # All diagnostics MUST go to stderr — stdout is reserved for JSON-RPC
        Log.setup(:warn, Log::IOBackend.new(STDERR))
        STDOUT.sync = true

        STDERR.puts "Starting chiasmus MCP server v#{Chiasmus::VERSION}"
        STDERR.puts "  Formal verification with Z3, Prolog, and tree-sitter analysis"
        STDERR.puts "  Run 'chiasmus --help' for usage options"
        STDERR.puts "  Waiting for MCP client connection on stdio..."

        mcp = build_mcp_transport
        wg = WaitGroup.new(1)

        mcp.on_close do
          STDERR.puts "[Chiasmus] MCP server shutting down"
          @skill_library.close rescue nil
          wg.done
        end

        Signal::INT.trap do
          mcp.close rescue nil
          wg.done
        end

        Signal::TERM.trap do
          mcp.close rescue nil
          wg.done
        end

        # Async self-healthcheck: validates server tools and state after startup
        # without blocking the MCP client connection. Uses in-memory transport
        # so stdout (reserved for JSON-RPC) is never touched.
        wg.spawn do
          sleep(500.milliseconds)
          result = healthcheck
          if result[:success]
            STDERR.puts "[Chiasmus] self healthcheck OK — #{result[:tools]} tools, v#{result[:version]}"
          else
            STDERR.puts "[Chiasmus] self healthcheck FAILED — #{result[:error]}"
          end
        rescue ex
          STDERR.puts "[Chiasmus] self healthcheck error — #{ex.message}"
        end

        wg.spawn { mcp.connect(MCP::Server::StdioServerTransport.new(STDIN, STDOUT)) }
        wg.wait
      end

      # Perform an in-memory healthcheck: MCP initialize + tools/list
      def healthcheck : NamedTuple(success: Bool, tools: Int32?, version: String?, error: String?)
        mcp = build_mcp_transport

        server_t = MCP::Shared::InMemoryTransport.new
        client_t = MCP::Shared::InMemoryTransport.new
        server_t.other_transport = client_t
        client_t.other_transport = server_t

        mcp.connect(server_t)

        client = MCP::Client::Client.new(
          MCP::Protocol::Implementation.new(name: "healthcheck", version: Chiasmus::VERSION)
        )

        begin
          client.connect(client_t)
          result = client.list_tools

          {
            success: true,
            tools:   result.try(&.tools.size) || 0,
            version: Chiasmus::VERSION,
            error:   nil,
          }
        rescue ex
          {
            success: false,
            tools:   nil,
            version: nil,
            error:   ex.message,
          }
        ensure
          mcp.close rescue nil
          client.close rescue nil
        end
      end

      # Run the MCP server on streamable HTTP transport for debugging
      def run_streamable(port : Int32 = 8899)
        mcp = build_mcp_transport
        runner = MCP::StreamableRunner.new(mcp, "/mcp")
        runner.run(port)
      end

      # Build and wire the MCP transport server with all tools registered
      def build_mcp_transport : MCP::Server::Server
        capabilities = MCP::Protocol::ServerCapabilities.new(
          tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
        )
        options = MCP::Server::ServerOptions.new(capabilities: capabilities)

        mcp_server = MCP::Server::Server.new(
          MCP::Protocol::Implementation.new(name: "chiasmus", version: Chiasmus::VERSION),
          options
        )

        register_tools(mcp_server)
        mcp_server
      end

      # Whether an LLM agent has been configured (via with_agent).
      # When false, chiasmus_learn is gated from the tool listing because it
      # requires an LLM to extract templates. Other tools degrade gracefully.
      private def llm_configured? : Bool
        !@formalization_engine.nil?
      end

      private def register_tools(mcp_server : MCP::Server::Server)
        tool_defs = [
          {Tools::VerifyTool, Tools::VerifyTool.tool_name, Tools::VerifyTool.tool_description, Tools::VerifyTool.input_schema},
          {Tools::SkillsTool, Tools::SkillsTool.tool_name, Tools::SkillsTool.tool_description, Tools::SkillsTool.input_schema},
          {Tools::FormalizeTool, Tools::FormalizeTool.tool_name, Tools::FormalizeTool.tool_description, Tools::FormalizeTool.input_schema},
          {Tools::SolveTool, Tools::SolveTool.tool_name, Tools::SolveTool.tool_description, Tools::SolveTool.input_schema},
          {Tools::LearnTool, Tools::LearnTool.tool_name, Tools::LearnTool.tool_description, Tools::LearnTool.input_schema},
          {Tools::LintTool, Tools::LintTool.tool_name, Tools::LintTool.tool_description, Tools::LintTool.input_schema},
          {Tools::GraphTool, Tools::GraphTool.tool_name, Tools::GraphTool.tool_description, Tools::GraphTool.input_schema},
          {Tools::MapTool, Tools::MapTool.tool_name, Tools::MapTool.tool_description, Tools::MapTool.input_schema},
          {Tools::SearchTool, Tools::SearchTool.tool_name, Tools::SearchTool.tool_description, Tools::SearchTool.input_schema},
          {Tools::CraftTool, Tools::CraftTool.tool_name, Tools::CraftTool.tool_description, Tools::CraftTool.input_schema},
          {Tools::ReviewTool, Tools::ReviewTool.tool_name, Tools::ReviewTool.tool_description, Tools::ReviewTool.input_schema},
          {Tools::CrigTool, Tools::CrigTool.tool_name, Tools::CrigTool.tool_description, Tools::CrigTool.input_schema},
        ]

        # Gate tools whose required backend is not configured.
        # chiasmus_learn requires an LLM to extract reusable templates.
        # chiasmus_search requires an embedding provider.
        gated = tool_defs.reject do |(tool_class, name, _, _)|
          (name == "chiasmus_learn" && !llm_configured?)
        end

        gated.each do |(tool_class, name, description, input_schema)|
          tool_instance = tool_class.new
          @tool_handlers[name] = ->(arguments : Hash(String, JSON::Any)) do
            build_call_tool_result(safely_invoke_tool(tool_instance, arguments))
          end

          mcp_server.add_tool(name, description, input_schema) do |params|
            arguments = params.arguments || {} of String => JSON::Any
            @tool_handlers[name].call(arguments)
          end
        end

        mcp_server.request_handler(MCP::Protocol::ToolsCall) do |request, extra|
          dispatch_tool_call(request.as(MCP::Protocol::CallToolRequestParams), extra)
        end
      end

      # Get chiasmus home directory (delegates to Config)
      def self.chiasmus_home : String
        Utils::Config.chiasmus_home
      end

      private def dispatch_tool_call(
        request : MCP::Protocol::CallToolRequestParams,
        extra : MCP::Shared::RequestHandlerExtra,
      ) : MCP::Protocol::CallToolResult
        handler = @tool_handlers[request.name]?
        return build_call_tool_result(Types::ErrorResponse.new("Tool not found: #{request.name}")) unless handler

        result_channel = @tool_dispatcher.dispatch do
          arguments = request.arguments || {} of String => JSON::Any
          handler.call(arguments)
        rescue ex
          build_call_tool_result(Types::ErrorResponse.new(ex.message || ex.class.name))
        end

        wait_for_tool_result(result_channel, extra, request.name)
      end

      private def wait_for_tool_result(
        result_channel : Channel(MCP::Protocol::CallToolResult),
        extra : MCP::Shared::RequestHandlerExtra,
        tool_name : String,
      ) : MCP::Protocol::CallToolResult
        if cancel_channel = extra.cancel_channel
          cancelled = cancellation_signal(cancel_channel)

          select
          when result = result_channel.receive?
            result || build_call_tool_result(Types::ErrorResponse.new("Tool request finished without a result: #{tool_name}"))
          when cancelled.receive?
            build_call_tool_result(Types::ErrorResponse.new("Tool request cancelled: #{tool_name}"))
          end
        else
          result_channel.receive? || build_call_tool_result(Types::ErrorResponse.new("Tool request finished without a result: #{tool_name}"))
        end
      end

      private def cancellation_signal(cancel_channel : Channel(Nil)) : Channel(Bool)
        signal = Channel(Bool).new(1)

        spawn do
          cancel_channel.receive?
          signal.send(true)
        rescue Channel::ClosedError
        ensure
          signal.close
        end

        signal
      end

      private def safely_invoke_tool(tool_instance, arguments : Hash(String, JSON::Any)) : Types::Response
        tool_instance.invoke(arguments)
      rescue ex
        Types::ErrorResponse.new(ex.message || ex.class.name)
      end

      private def build_call_tool_result(result : Types::Response) : MCP::Protocol::CallToolResult
        result_json = result.to_json
        content = [MCP::Protocol::TextContentBlock.new(result_json)] of MCP::Protocol::ContentBlock
        structured = begin
          JSON.parse(result_json).as_h
        rescue
          nil
        end
        MCP::Protocol::CallToolResult.new(content: content, structured_content: structured)
      end

      private def build_skill_extractor(agent : Crig::Agent(M)) : Skills::Learner::Extractor
        ->(solver : Solvers::SolverType, verified_spec : String, problem_description : String) do
          agent.prompt(
            <<-CONTENT
            #{Skills::Learner::EXTRACT_SYSTEM}

            SOLVER: #{solver.to_s.downcase}
            VERIFIED SPECIFICATION:
            #{verified_spec}

            PROBLEM DESCRIPTION: #{problem_description}

            Extract a reusable template from this verified solution.
            CONTENT
          ).send_async.receive.unwrap
        end
      end
    end
  end
end
