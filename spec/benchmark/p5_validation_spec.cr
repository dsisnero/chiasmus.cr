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
      age_gap = result.gaps.find { |gap_item| gap_item.field == "age" }
      age_gap.should_not be_nil
    end

    it "finds the username_length gap (frontend allows 21-30, backend max 20)" do
      result = Benchmark::Traditional.solve_validation(input)
      username_gap = result.gaps.find { |gap_item| gap_item.field == "username_length" }
      username_gap.should_not be_nil
    end

    it "provides a concrete example for the age gap" do
      result = Benchmark::Traditional.solve_validation(input)
      age_gap = result.gaps.find { |gap_item| gap_item.field == "age" }
      age_gap.should_not be_nil
      raise "expected non-nil age_gap" if age_gap.nil?
      example = age_gap.example
      example.should_not be_nil
      raise "expected non-nil example" if example.nil?
      age_val = example["age"]
      age_val.should be >= 13
      age_val.should be < 18
    end

    it "provides a concrete example for the username_length gap" do
      result = Benchmark::Traditional.solve_validation(input)
      gap = result.gaps.find { |gap_item| gap_item.field == "username_length" }
      gap.should_not be_nil
      raise "expected non-nil gap" if gap.nil?
      example = gap.example
      example.should_not be_nil
      raise "expected non-nil example" if example.nil?
      len = example["username_length"]
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
      age_gap = result.gaps.find { |gap_item| gap_item.field == "age" }
      age_gap.should_not be_nil
    end

    it "finds the username_length gap (frontend allows 21-30, backend max 20)" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      username_gap = result.gaps.find { |gap_item| gap_item.field == "username_length" }
      username_gap.should_not be_nil
    end

    it "provides a concrete example for the age gap" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      age_gap = result.gaps.find { |gap_item| gap_item.field == "age" }
      age_gap.should_not be_nil
      raise "expected non-nil age_gap" if age_gap.nil?
      example = age_gap.example
      example.should_not be_nil
      raise "expected non-nil example" if example.nil?
      age_val = example["age"]
      age_val.should be >= 13
      age_val.should be < 18
    end

    it "provides a concrete example for the username_length gap" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_validation(input)
      gap = result.gaps.find { |gap_item| gap_item.field == "username_length" }
      gap.should_not be_nil
      raise "expected non-nil gap" if gap.nil?
      example = gap.example
      example.should_not be_nil
      raise "expected non-nil example" if example.nil?
      len = example["username_length"]
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
