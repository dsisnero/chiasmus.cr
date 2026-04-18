require "file_utils"
require "process"
require "json"

module Chiasmus
  module Graph
    # Non-blocking grammar operations
    module GrammarOperations
      extend self

      # Check if tree-sitter CLI is available (non-blocking check)
      def check_tree_sitter_cli_async : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            result = Process.run("which", ["tree-sitter"],
              output: Process::Redirect::Pipe,
              error: Process::Redirect::Pipe
            )

            channel.send(result.success?)
          rescue
            channel.send(false)
          end
        end

        channel
      end

      # Run a command asynchronously and return output
      def run_command_async(command : String, args : Array(String) = [] of String) : Channel(Tuple(Bool, String, String))
        channel = Channel(Tuple(Bool, String, String)).new

        spawn do
          output = IO::Memory.new
          error = IO::Memory.new

          begin
            result = Process.run(command, args,
              output: output,
              error: error
            )

            channel.send({result.success?, output.to_s, error.to_s})
          rescue ex
            channel.send({false, "", ex.message.to_s})
          end
        end

        channel
      end

      # Clone a git repository asynchronously
      def git_clone_async(repo_url : String, target_dir : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            Dir.mkdir_p(File.dirname(target_dir))

            result_channel = run_command_async("git", ["clone", repo_url, target_dir])
            success, _, _ = result_channel.receive

            channel.send(success)
          rescue
            channel.send(false)
          end
        end

        channel
      end

      # Git pull asynchronously
      def git_pull_async(repo_dir : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          original_dir = Dir.current
          begin
            Dir.cd(repo_dir)
            result_channel = run_command_async("git", ["pull"])
            success, _, _ = result_channel.receive
            channel.send(success)
          rescue
            channel.send(false)
          ensure
            Dir.cd(original_dir)
          end
        end

        channel
      end

      # npm install asynchronously
      def npm_install_async(package : String, install_dir : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          original_dir = Dir.current
          begin
            Dir.mkdir_p(install_dir)
            Dir.cd(install_dir)

            # Initialize package.json if needed
            unless File.exists?("package.json")
              init_channel = run_command_async("npm", ["init", "-y"])
              init_success, _, _ = init_channel.receive
              unless init_success
                channel.send(false)
                next
              end
            end

            # Install package
            install_channel = run_command_async("npm", ["install", package])
            install_success, _, _ = install_channel.receive
            channel.send(install_success)
          rescue
            channel.send(false)
          ensure
            Dir.cd(original_dir)
          end
        end

        channel
      end

      # Generate parser with tree-sitter asynchronously
      def tree_sitter_generate_async(grammar_js_path : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            result_channel = run_command_async("tree-sitter", ["generate", grammar_js_path])
            success, _, _ = result_channel.receive
            channel.send(success)
          rescue
            channel.send(false)
          end
        end

        channel
      end

      # Compile shared library asynchronously
      def compile_shared_library_async(source_dir : String, language : String) : Channel(Tuple(Bool, String?))
        channel = Channel(Tuple(Bool, String?)).new

        spawn do
          original_dir = Dir.current
          begin
            Dir.cd(source_dir)

            # Find source files
            src_files = Dir.glob("src/*.c")
            if src_files.empty?
              channel.send({false, "No C source files found in src/"})
              next
            end

            # Build command
            ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
            output_file = "libtree-sitter-#{language}.#{ext}"

            build_cmd = "cc -shared -fPIC -I./src -o #{output_file} #{src_files.join(" ")}"

            # Compile
            result_channel = run_command_async("sh", ["-c", build_cmd])
            success, _, error = result_channel.receive

            if success
              channel.send({true, File.join(source_dir, output_file)})
            else
              channel.send({false, "Compilation failed: #{error}"})
            end
          rescue ex
            channel.send({false, ex.message})
          ensure
            Dir.cd(original_dir)
          end
        end

        channel
      end

      # Copy files asynchronously
      def copy_file_async(src : String, dest : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            FileUtils.cp(src, dest)
            channel.send(true)
          rescue ex
            channel.send(false)
          end
        end

        channel
      end

      # Create directory asynchronously
      def create_dir_async(path : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            Dir.mkdir_p(path)
            channel.send(true)
          rescue
            channel.send(false)
          end
        end

        channel
      end

      # Check if file exists asynchronously
      def file_exists_async(path : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            channel.send(File.exists?(path))
          rescue
            channel.send(false)
          end
        end

        channel
      end

      # Check if directory exists asynchronously
      def dir_exists_async(path : String) : Channel(Bool)
        channel = Channel(Bool).new

        spawn do
          begin
            channel.send(Dir.exists?(path))
          rescue
            channel.send(false)
          end
        end

        channel
      end
    end
  end
end
