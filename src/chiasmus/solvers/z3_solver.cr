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
        # Nothing to dispose for Z3
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
        # Sanitize input - remove commands we handle ourselves
        sanitized = sanitize_smtlib(smtlib)

        if sanitized.empty?
          return SolverResult.new(status: "sat", model: {} of String => String)
        end

        # Prepare Z3 command
        z3_input = "(set-option :produce-unsat-cores true)\n#{sanitized}\n(check-sat)\n(get-model)\n(get-unsat-core)"

        # Run Z3
        output = run_z3(z3_input)

        # Parse result
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

      private def run_z3(input : String) : String
        # Write input to temp file
        temp_file = File.tempfile("z3_input", ".smt2") do |file|
          file.puts(input)
        end

        # Run Z3
        output = IO::Memory.new
        error = IO::Memory.new

        Process.run("z3", ["-smt2", temp_file.path], output: output, error: error)

        # Clean up temp file
        File.delete(temp_file.path)

        output.to_s
      rescue ex
        "error: #{ex.message}"
      end

      private def parse_z3_output(output : String) : SolverResult
        lines = output.lines.map(&.strip).reject(&.empty?)

        # Check for sat/unsat/unknown
        if lines.empty?
          return SolverResult.new(status: "error", error: "Empty response from Z3")
        end

        first_line = lines[0]

        case first_line
        when "sat"
          parse_sat_output(lines)
        when "unsat"
          parse_unsat_output(lines)
        when "unknown"
          SolverResult.new(status: "unknown", reason: lines[1..].join(' '))
        else
          # Check if it's an error message
          if output.includes?("error")
            SolverResult.new(status: "error", error: output)
          else
            SolverResult.new(status: "error", error: "Unexpected Z3 output: #{output}")
          end
        end
      end

      private def parse_sat_output(lines : Array(String)) : SolverResult
        model = {} of String => String

        # Parse model lines
        # Format is usually:
        # sat
        # (
        #   (define-fun y () Int
        #     4)
        #   (define-fun x () Int
        #     6)
        # )
        in_model = false
        current_var = ""
        current_value = ""
        in_define_fun = false

        lines[1..].each do |line|
          if line == "("
            in_model = true
            next
          elsif line == ")"
            break
          elsif in_model
            if line.starts_with?("(define-fun ")
              # Start of define-fun
              in_define_fun = true
              if match = line.match(/\(define-fun\s+(\w+)\s+\(\)\s+\w+/)
                current_var = match[1]
                current_value = ""
              end
            elsif in_define_fun && line.ends_with?(")")
              # End of define-fun
              value_part = line[0...-1].strip
              current_value += value_part unless value_part.empty?
              model[current_var] = current_value.strip
              in_define_fun = false
              current_var = ""
              current_value = ""
            elsif in_define_fun
              # Inside define-fun value
              current_value += line.strip + " "
            end
          end
        end

        SolverResult.new(status: "sat", model: model)
      end

      private def parse_unsat_output(lines : Array(String)) : SolverResult
        unsat_core = [] of String

        # Parse unsat core lines
        # Format is usually:
        # unsat
        # (error "...")  # if get-model was called
        # (a1 a2)
        lines[1..].each do |line|
          next unless line.starts_with?("(") && line.ends_with?(")")
          next if line.starts_with?("(error ")

          # Extract core elements
          line[1...-1].split.each do |item|
            unsat_core << item unless item.empty?
          end
          break
        end

        SolverResult.new(status: "unsat", unsat_core: unsat_core)
      end
    end
  end
end
