require "../spec_helper"

private def z3_available?
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Benchmark: Problem 2 - Package Dependency Resolution" do
  input = {
    packages:          Benchmark::Problems::PackageConstraints[:packages],
    requirements:      Benchmark::Problems::PackageConstraints[:requirements],
    incompatibilities: Benchmark::Problems::PackageConstraints[:incompatibilities],
  }

  describe "Traditional" do
    it "finds a satisfiable assignment" do
      result = Benchmark::Traditional.solve_deps(input)
      result.satisfiable.should be_true
      result.assignment.should_not be_nil
    end

    it "all versions are within allowed ranges" do
      result = Benchmark::Traditional.solve_deps(input)
      a = result.assignment.not_nil!
      input[:packages].each do |pkg, info|
        info[:versions].should contain(a[pkg])
      end
    end

    it "respects dependency requirements" do
      result = Benchmark::Traditional.solve_deps(input)
      a = result.assignment.not_nil!
      input[:requirements].each do |req|
        next if (cond = req[:condition]) && a[req[:package]] < cond
        a[req[:requires]].should be >= req[:minVersion]
      end
    end

    it "respects incompatibilities" do
      result = Benchmark::Traditional.solve_deps(input)
      a = result.assignment.not_nil!
      input[:incompatibilities].each do |inc|
        both_match = a[inc[:packageA]] == inc[:versionA] && a[inc[:packageB]] == inc[:versionB]
        both_match.should be_false
      end
    end
  end

  describe "Chiasmus (Z3)" do
    it "finds a satisfiable assignment" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_deps(input)
      result.satisfiable.should be_true
      result.assignment.should_not be_nil
    end

    it "all versions are within allowed ranges" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_deps(input)
      a = result.assignment.not_nil!
      input[:packages].each do |pkg, info|
        info[:versions].should contain(a[pkg])
      end
    end

    it "respects dependency requirements" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_deps(input)
      a = result.assignment.not_nil!
      input[:requirements].each do |req|
        next if (cond = req[:condition]) && a[req[:package]] < cond
        a[req[:requires]].should be >= req[:minVersion]
      end
    end

    it "respects incompatibilities" do
      next pending("z3 not installed") unless z3_available?

      result = Benchmark::Chiasmus.solve_deps(input)
      a = result.assignment.not_nil!
      input[:incompatibilities].each do |inc|
        both_match = a[inc[:packageA]] == inc[:versionA] && a[inc[:packageB]] == inc[:versionB]
        both_match.should be_false
      end
    end
  end
end
