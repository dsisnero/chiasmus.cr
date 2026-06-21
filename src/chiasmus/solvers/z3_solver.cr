require "json"

module Chiasmus
  module Solvers
    class Z3Solver < Solver
      record SolverResult, status : String, model : Hash(String, String) = Hash(String, String).new, unsat_core : Array(String) = [] of String, error : String = "", reason : String = "" do
        include JSON::Serializable
      end

      def initialize
      end

      def type : SolverType
        SolverType::Z3
      end

      def solve(input : SolverInput) : Solvers::SolverResult
        case input
        when Z3SolverInput
          result = solve_z3(input.smtlib)
          convert_result(result)
        else
          raise "Z3Solver only supports Z3SolverInput"
        end
      end

      def dispose : Nil
      end

      private def convert_result(result : SolverResult) : Solvers::SolverResult
        case result.status
        when "sat"
          Solvers::SatResult.new(result.model)
        when "unsat"
          Solvers::UnsatResult.new(result.unsat_core)
        when "unknown"
          Solvers::UnknownResult.new
        else
          Solvers::ErrorResult.new(result.error)
        end
      end

      private def solve_z3(smtlib : String) : SolverResult
        sanitized = sanitize_smtlib(smtlib)
        if sanitized.empty?
          return SolverResult.new(status: "sat", model: {} of String => String)
        end

        z3_input = "(echo \"<<<Z3_DONE>>>\")\n#{sanitized}\n(check-sat)\n(get-model)\n(get-unsat-core)\n(echo \"<<<Z3_DONE>>>\")"
        output = run_z3_persistent(z3_input)
        parse_z3_output(output)
      end

      private def sanitize_smtlib(input : String) : String
        input
          .gsub(/\(\s*check-sat\s*\)/, "")
          .gsub(/\(\s*get-model\s*\)/, "")
          .gsub(/\(\s*get-unsat-core\s*\)/, "")
          .gsub(/\(\s*exit\s*\)/, "")
          .gsub(/\(\s*set-option\s+:produce-unsat-cores\s+\w+\s*\)/, "")
          .strip
      end

      # Run Z3 via persistent process — keeps Z3 alive between calls.
      # First call spawns the process; subsequent calls reuse it via pipe.
      private def run_z3_persistent(input : String) : String
        Z3Process.send_command(input)
      rescue ex
        # If persistent process fails, fall back to one-shot
        Z3Process.reset
        fallback_z3(input)
      end

      private def fallback_z3(input : String) : String
        temp_file = File.tempfile("z3_input", &.puts(input))
        begin
          output = IO::Memory.new
          Process.run("z3", ["-smt2", temp_file.path], output: output, error: output)
          output.to_s
        rescue ex
          "error: #{ex.message}"
        ensure
          File.delete(temp_file.path) rescue nil
        end
      end

      private def parse_z3_output(output : String) : SolverResult
        lines = output.lines.map(&.strip).reject(&.empty?)
        return SolverResult.new(status: "error", error: "Empty response from Z3") if lines.empty?

        first_line = lines[0]
        case first_line
        when "sat"
          parse_sat_output(lines)
        when "unsat"
          parse_unsat_output(lines)
        when "unknown"
          SolverResult.new(status: "unknown", reason: lines[1..].join(' '))
        else
          if output.includes?("error")
            SolverResult.new(status: "error", error: output)
          else
            SolverResult.new(status: "error", error: "Unexpected Z3 output: #{output}")
          end
        end
      end

      private def parse_sat_output(lines : Array(String)) : SolverResult
        model = {} of String => String
        current_var = ""
        current_value = ""
        in_define_fun = false

        lines[1..].each do |line|
          if line == "("
            next
          elsif line == ")"
            break
          else
            if line.starts_with?("(define-fun ")
              in_define_fun = true
              if match = line.match(/\(define-fun\s+(\w+)\s+\(\)\s+\w+/)
                current_var = match[1]
                current_value = ""
              end
            elsif in_define_fun && line.ends_with?(")")
              value_part = line[0...-1].strip
              current_value += value_part unless value_part.empty?
              model[current_var] = current_value.strip
              in_define_fun = false
              current_var = ""
              current_value = ""
            elsif in_define_fun
              current_value += line.strip + " "
            end
          end
        end

        SolverResult.new(status: "sat", model: model)
      end

      private def parse_unsat_output(lines : Array(String)) : SolverResult
        unsat_core = [] of String
        lines[1..].each do |line|
          next unless line.starts_with?("(") && line.ends_with?(")")
          next if line.starts_with?("(error ")
          line[1...-1].split.each { |item| unsat_core << item unless item.empty? }
          break
        end
        SolverResult.new(status: "unsat", unsat_core: unsat_core)
      end
    end

    # Persistent Z3 process — one instance shared across all Z3Solver instances.
    # Mutex-protected for fiber safety.
    module Z3Process
      extend self

      @@process : Process?
      @@output : IO::FileDescriptor?
      @@input : IO::FileDescriptor?
      @@lock = Mutex.new

      private def ensure_process : Process
        @@lock.synchronize do
          unless @@process
            p = Process.new("z3", ["-smt2", "-in"],
              input: Process::Redirect::Pipe,
              output: Process::Redirect::Pipe,
              error: Process::Redirect::Pipe)
            @@process = p
            @@output = p.output.as(IO::FileDescriptor)
            @@input = p.input.as(IO::FileDescriptor)
            @@input.try(&.puts("(set-option :produce-unsat-cores true)"))
            @@input.try(&.flush)
          end
          p = @@process
          raise "Failed to start Z3 process" unless p
          p
        end
      end

      def send_command(smtlib : String) : String
        ensure_process
        inp = @@input.as(IO::FileDescriptor)
        out = @@output.as(IO::FileDescriptor)

        @@lock.synchronize do
          inp.puts(smtlib)
          inp.puts("(reset)")
          inp.flush

          result = [] of String
          errors = [] of String
          skipped_first = false

          loop do
            line = out.gets
            break unless line
            line = line.strip
            if line == "<<<Z3_DONE>>>"
              break if skipped_first
              skipped_first = true
              next
            end
            if line.starts_with?("(error ")
              # Ignore expected errors from requesting model on UNSAT / core on SAT
              unless line.includes?("model is not available") || line.includes?("unsat core is not available")
                errors << line
              end
            elsif skipped_first
              result << line unless line.empty?
            end
          end

          unless errors.empty?
            return "error: #{errors.join("\n")}"
          end

          result.join("\n")
        end
      rescue ex
        "error: #{ex.message}"
      end

      def reset : Nil
        @@lock.synchronize do
          @@input.try(&.close)
          @@process.try(&.terminate)
          @@process = nil
          @@output = nil
          @@input = nil
        end
      end
    end
  end
end
