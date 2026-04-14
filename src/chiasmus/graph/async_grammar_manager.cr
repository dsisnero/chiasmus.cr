require "file_utils"
require "process"
require "json"
require "tree_sitter"
require "../utils/xdg"
require "./language_loader"

module Chiasmus
  module Graph
    # Async grammar manager that uses fibers and channels for non-blocking operations
    class AsyncGrammarManager
      # Request types for the worker
      enum RequestType
        EnsureGrammar    # Ensure a grammar is available
        GetGrammarPath   # Get path to a grammar
        GrammarAvailable # Check if grammar is available
        Shutdown         # Shutdown the worker
      end

      # Request message
      class Request
        getter type : RequestType
        getter language : String?
        getter response_channel : Channel(Response)

        def initialize(@type : RequestType, @language : String? = nil)
          @response_channel = Channel(Response).new
        end
      end

      # Response message
      class Response
        getter success : Bool
        getter data : String?
        getter error : String?

        def initialize(@success : Bool, @data : String? = nil, @error : String? = nil)
        end
      end

      @@instance : AsyncGrammarManager?
      @@request_channel = Channel(Request).new
      @@worker_started = false

      # Singleton instance
      def self.instance : AsyncGrammarManager
        @@instance ||= new
      end

      # Start the worker fiber
      def self.start_worker(cache_dir : String? = nil)
        return if @@worker_started

        spawn do
          worker_loop(cache_dir)
        end

        @@worker_started = true
      end

      # Worker main loop (private class method)
      private def self.worker_loop(cache_dir : String? = nil)
        # Initialize sync grammar manager (for actual operations)
        sync_manager = SyncGrammarManager.new(cache_dir)

        loop do
          request = @@request_channel.receive

          case request.type
          when RequestType::EnsureGrammar
            handle_ensure_grammar(request, sync_manager)
          when RequestType::GetGrammarPath
            handle_get_grammar_path(request, sync_manager)
          when RequestType::GrammarAvailable
            handle_grammar_available(request, sync_manager)
          when RequestType::Shutdown
            request.response_channel.send(Response.new(true))
            break
          end
        end
      end

      # Ensure a grammar is available (async)
      def self.ensure_grammar_async(language : String) : Channel(Bool)
        start_worker

        response_channel = Channel(Bool).new

        spawn do
          request = Request.new(RequestType::EnsureGrammar, language)
          @@request_channel.send(request)

          response = request.response_channel.receive
          response_channel.send(response.success)
        end

        response_channel
      end

      # Get grammar path (async)
      def self.get_grammar_path_async(language : String) : Channel(String?)
        start_worker

        response_channel = Channel(String?).new

        spawn do
          request = Request.new(RequestType::GetGrammarPath, language)
          @@request_channel.send(request)

          response = request.response_channel.receive
          response_channel.send(response.success ? response.data : nil)
        end

        response_channel
      end

      # Check if grammar is available (async)
      def self.grammar_available_async(language : String) : Channel(Bool)
        start_worker

        response_channel = Channel(Bool).new

        spawn do
          request = Request.new(RequestType::GrammarAvailable, language)
          @@request_channel.send(request)

          response = request.response_channel.receive
          response_channel.send(response.success)
        end

        response_channel
      end

      # Shutdown the worker
      def self.shutdown
        return unless @@worker_started

        request = Request.new(RequestType::Shutdown)
        @@request_channel.send(request)

        # Wait for response
        request.response_channel.receive
        @@worker_started = false
      end

      # Handle ensure grammar request
      private def self.handle_ensure_grammar(request : Request, sync_manager : SyncGrammarManager)
        language = request.language.not_nil!

        begin
          success = sync_manager.ensure_grammar(language)
          request.response_channel.send(Response.new(success))
        rescue ex
          request.response_channel.send(Response.new(false, error: ex.message))
        end
      end

      # Handle get grammar path request
      private def self.handle_get_grammar_path(request : Request, sync_manager : SyncGrammarManager)
        language = request.language.not_nil!

        begin
          path = sync_manager.get_grammar_path(language)
          if path
            request.response_channel.send(Response.new(true, data: path))
          else
            request.response_channel.send(Response.new(false))
          end
        rescue ex
          request.response_channel.send(Response.new(false, error: ex.message))
        end
      end

      # Handle grammar available request
      private def self.handle_grammar_available(request : Request, sync_manager : SyncGrammarManager)
        language = request.language.not_nil!

        begin
          available = sync_manager.grammar_available?(language)
          request.response_channel.send(Response.new(available))
        rescue ex
          request.response_channel.send(Response.new(false, error: ex.message))
        end
      end

      # Internal sync grammar manager (wraps the original blocking implementation)
      private class SyncGrammarManager
        @cache_dir : String?

        def initialize(cache_dir : String? = nil)
          @cache_dir = cache_dir || default_cache_dir
          Dir.mkdir_p(@cache_dir.not_nil!)
        end

        # Check if a grammar is available
        def grammar_available?(language : String) : Bool
          # Check if we can get a path to the grammar
          get_grammar_path(language) != nil
        end

        # Get the path to a built grammar shared library
        def get_grammar_path(language : String) : String?
          # Look in standard locations via repository
          language_paths = LanguageLoader.repository_language_paths
          if path = language_paths[language]?
            ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
            so_path = path.join("libtree-sitter-#{language}.#{ext}")
            return so_path.to_s if File.exists?(so_path)
          end

          # Also check our cache directory
          if cache_dir = @cache_dir
            # Check in cache_dir/tree-sitter-language/
            ts_cache_path = File.join(cache_dir, "tree-sitter-#{language}")
            ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
            ts_so_path = File.join(ts_cache_path, "libtree-sitter-#{language}.#{ext}")
            return ts_so_path if File.exists?(ts_so_path)
          end

          nil
        end

        # Ensure a grammar is available
        def ensure_grammar(language : String) : Bool
          # Check if already available
          return true if grammar_available?(language)

          puts "Grammar for #{language} not found. Attempting to make it available..."

          # Try to build/download (simplified - would delegate to original GrammarManager)
          # For now, just return false
          false
        end

        private def default_cache_dir : String
          Utils::XDG.grammar_cache_dir
        end
      end
    end
  end
end
