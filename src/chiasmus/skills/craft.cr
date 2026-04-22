module Chiasmus
  module Skills
    record CraftInput,
      name : String,
      domain : String,
      solver : String,
      signature : String,
      skeleton : String,
      slots : Array(SlotDef),
      normalizations : Array(Normalization),
      tips : Array(String)? = nil,
      example : String? = nil,
      test : Bool = false

    record CraftResult,
      created : Bool,
      template : String? = nil,
      domain : String? = nil,
      solver : String? = nil,
      slots : Int32? = nil,
      tested : Bool = false,
      test_result : String? = nil,
      errors : Array(String)? = nil

    VALID_SOLVERS = {"z3", "prolog"}

    def self.validate_template(input : CraftInput, library : Library) : Array(String)
      errors = [] of String

      validate_required_fields(input, errors)
      validate_solver(input.solver, errors)
      validate_name(input.name, library, errors)
      validate_slots(input.slots, errors)
      validate_normalizations(input.normalizations, errors)
      validate_skeleton_slots(input.skeleton, input.slots, errors)

      errors
    end

    def self.craft_template(input : CraftInput, library : Library) : CraftResult
      errors = validate_template(input, library)
      return CraftResult.new(created: false, errors: errors) unless errors.empty?
      solver_type = parse_solver(input.solver)
      return CraftResult.new(created: false, errors: ["Unsupported solver: #{input.solver}"]) unless solver_type

      template = SkillTemplate.new(
        name: input.name,
        domain: input.domain,
        solver: solver_type,
        signature: input.signature,
        skeleton: input.skeleton,
        slots: input.slots,
        normalizations: input.normalizations,
        tips: input.tips,
        example: input.example
      )

      tested = false
      test_result = nil.as(String?)
      if input.test && (example = input.example)
        tested = true
        test_result = run_template_test(template.solver, example)
      end

      added = library.add_learned(template)
      unless added
        return CraftResult.new(
          created: false,
          errors: ["Failed to add template \"#{input.name}\" to library"]
        )
      end

      CraftResult.new(
        created: true,
        template: input.name,
        domain: input.domain,
        solver: input.solver,
        slots: input.slots.size,
        tested: tested,
        test_result: test_result
      )
    end

    private def self.validate_required_fields(input : CraftInput, errors : Array(String)) : Nil
      {
        "name"      => input.name,
        "domain"    => input.domain,
        "solver"    => input.solver,
        "signature" => input.signature,
        "skeleton"  => input.skeleton,
      }.each do |field, value|
        errors << "'#{field}' is required and must be a non-empty string" if value.blank?
      end
    end

    private def self.validate_solver(solver : String, errors : Array(String)) : Nil
      return if VALID_SOLVERS.includes?(solver)

      errors << "'solver' must be \"z3\" or \"prolog\", got \"#{solver}\""
    end

    private def self.validate_name(name : String, library : Library, errors : Array(String)) : Nil
      return if name.blank?

      unless /^[a-z][a-z0-9-]*$/ =~ name
        errors << "'name' must be kebab-case (lowercase letters, digits, hyphens)"
      end

      if library.get(name)
        errors << "Template \"#{name}\" already exists in library"
      end
    end

    private def self.validate_slots(slots : Array(SlotDef), errors : Array(String)) : Nil
      if slots.empty?
        errors << "'slots' must be a non-empty array"
        return
      end

      slots.each_with_index do |slot, index|
        if slot.name.blank? || slot.description.blank? || slot.format.blank?
          errors << "slots[#{index}] must have non-empty 'name', 'description', and 'format'"
        end
      end
    end

    private def self.validate_normalizations(normalizations : Array(Normalization), errors : Array(String)) : Nil
      if normalizations.empty?
        errors << "'normalizations' must be a non-empty array"
        return
      end

      normalizations.each_with_index do |normalization, index|
        if normalization.source.blank? || normalization.transform.blank?
          errors << "normalizations[#{index}] must have non-empty 'source' and 'transform'"
        end
      end
    end

    private def self.validate_skeleton_slots(skeleton : String, slots : Array(SlotDef), errors : Array(String)) : Nil
      skeleton_slots = skeleton.scan(/\{\{SLOT:(\w+)\}\}/).map(&.[1]).to_set
      defined_slots = slots.map(&.name).to_set

      skeleton_slots.each do |name|
        unless defined_slots.includes?(name)
          errors << "Slot '#{name}' referenced in skeleton but not defined in slots array"
        end
      end

      defined_slots.each do |name|
        unless skeleton_slots.includes?(name)
          errors << "Slot '#{name}' defined in slots array but not referenced in skeleton"
        end
      end
    end

    private def self.parse_solver(solver : String) : Solvers::SolverType?
      case solver
      when "z3"     then Solvers::SolverType::Z3
      when "prolog" then Solvers::SolverType::Prolog
      else               nil
      end
    end

    private def self.run_template_test(solver_type : Solvers::SolverType, example : String) : String
      solver = Solvers::Factory.build(solver_type)
      begin
        result = solver.solve(build_solver_input(solver_type, example))
        result.status
      rescue ex
        "error: #{ex.message || ex.class.name}"
      ensure
        solver.dispose
      end
    end

    private def self.build_solver_input(solver_type : Solvers::SolverType, example : String) : Solvers::SolverInput
      case solver_type
      when Solvers::SolverType::Z3
        Solvers::Z3SolverInput.new(example)
      when Solvers::SolverType::Prolog
        build_prolog_input(example)
      else
        raise "Unsupported solver type: #{solver_type}"
      end
    end

    private def self.build_prolog_input(example : String) : Solvers::PrologSolverInput
      lines = example.lines
      program = example
      query = "true."

      (lines.size - 1).downto(0) do |index|
        trimmed = lines[index].strip
        next unless trimmed.starts_with?("?-")

        query = trimmed.sub(/^\?\-\s*/, "")
        program = lines[0...index].join("\n").strip
        break
      end

      Solvers::PrologSolverInput.new(program, query)
    end
  end
end
