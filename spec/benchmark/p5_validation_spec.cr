require "../spec_helper"

private def z3_available?
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Benchmark: Problem 5 - API Validation Rule Consistency" do
  input = {
    fields:   Benchmark::Problems::ValidationFields,
    frontend: Benchmark::Problems::FrontendRules,
    backend:  Benchmark::Problems::BackendRules,
  }

  describe "Traditional" do
    it "finds the age gap (frontend allows 13-17, backend rejects)" do
      result = Benchmark::Traditional.solve_validation(input)
      age_gap = result.gaps.find { |g| g.field == "age" }
      age_gap.should_not be_nil
    end

    it "finds the username_length gap (frontend allows 21-30, backend max 20)" do
      result = Benchmark::Traditional.solve_validation(input)
      username_gap = result.gaps.find { |g| g.field == "username_length" }
      username_gap.should_not be_nil
    end

    it "provides a concrete example for the age gap" do
      result = Benchmark::Traditional.solve_validation(input)
      age_gap = result.gaps.find { |g| g.field == "age" }
      age_gap.should_not be_nil
      example = age_gap.not_nil!.example
      example.should_not be_nil
      age_val = example.not_nil!["age"]
      age_val.should be >= 13
      age_val.should be < 18
    end

    it "provides a concrete example for the username_length gap" do
      result = Benchmark::Traditional.solve_validation(input)
      gap = result.gaps.find { |g| g.field == "username_length" }
      gap.should_not be_nil
      example = gap.not_nil!.example
      example.should_not be_nil
      len = example.not_nil!["username_length"]
      len.should be > 20
      len.should be <= 30
    end

    it "finds exactly 2 gaps" do
      result = Benchmark::Traditional.solve_validation(input)
      result.gaps.size.should eq(2)
    end
  end

  describe "Chiasmus (Z3)" do
    it "finds the age gap (frontend allows 13-17, backend rejects)" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      age_gap = result.gaps.find { |g| g.field == "age" }
      age_gap.should_not be_nil
    end

    it "finds the username_length gap (frontend allows 21-30, backend max 20)" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      username_gap = result.gaps.find { |g| g.field == "username_length" }
      username_gap.should_not be_nil
    end

    it "provides a concrete example for the age gap" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      age_gap = result.gaps.find { |g| g.field == "age" }
      age_gap.should_not be_nil
      example = age_gap.not_nil!.example
      example.should_not be_nil
      age_val = example.not_nil!["age"]
      age_val.should be >= 13
      age_val.should be < 18
    end

    it "provides a concrete example for the username_length gap" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      gap = result.gaps.find { |g| g.field == "username_length" }
      gap.should_not be_nil
      example = gap.not_nil!.example
      example.should_not be_nil
      len = example.not_nil!["username_length"]
      len.should be > 20
      len.should be <= 30
    end

    it "finds exactly 2 gaps" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      result.gaps.size.should eq(2)
    end
  end
end
