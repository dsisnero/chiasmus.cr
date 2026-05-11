module Benchmark
  module Traditional
    record DependencyResult, satisfiable : Bool, assignment : Hash(String, Int32)?

    def self.solve_deps(input : NamedTuple(
                          packages: Hash(String, NamedTuple(versions: Array(Int32))),
                          requirements: Array(NamedTuple(package: String, requires: String, minVersion: Int32, condition: Int32?)),
                          incompatibilities: Array(NamedTuple(packageA: String, versionA: Int32, packageB: String, versionB: Int32)),
                        )) : DependencyResult
      pkg_names = input[:packages].keys

      backtrack = uninitialized (Int32, Hash(String, Int32) -> Hash(String, Int32)?)
      backtrack = ->(idx : Int32, assignment : Hash(String, Int32)) : Hash(String, Int32)? do
        if idx == pkg_names.size
          return valid_dependency_assignment?(assignment, input) ? assignment.dup : nil
        end

        pkg = pkg_names[idx]
        input[:packages][pkg][:versions].each do |ver|
          assignment[pkg] = ver
          if valid_dependency_assignment?(assignment, input)
            result = backtrack.call(idx + 1, assignment)
            return result if result
          end
        end
        assignment.delete(pkg)
        nil
      end

      assignment = backtrack.call(0, Hash(String, Int32).new)
      assignment ? DependencyResult.new(satisfiable: true, assignment: assignment) : DependencyResult.new(satisfiable: false, assignment: nil)
    end

    private def self.valid_dependency_assignment?(
      assignment : Hash(String, Int32),
      input : NamedTuple(
        packages: Hash(String, NamedTuple(versions: Array(Int32))),
        requirements: Array(NamedTuple(package: String, requires: String, minVersion: Int32, condition: Int32?)),
        incompatibilities: Array(NamedTuple(packageA: String, versionA: Int32, packageB: String, versionB: Int32)),
      ),
    ) : Bool
      requirements_satisfied?(assignment, input[:requirements]) &&
        incompatibilities_satisfied?(assignment, input[:incompatibilities])
    end

    private def self.requirements_satisfied?(
      assignment : Hash(String, Int32),
      requirements : Array(NamedTuple(package: String, requires: String, minVersion: Int32, condition: Int32?)),
    ) : Bool
      requirements.all? do |requirement|
        package_version = assignment[requirement[:package]]?
        next true unless package_version
        next true if (condition = requirement[:condition]) && package_version < condition

        dependency_version = assignment[requirement[:requires]]?
        next true unless dependency_version

        dependency_version >= requirement[:minVersion]
      end
    end

    private def self.incompatibilities_satisfied?(
      assignment : Hash(String, Int32),
      incompatibilities : Array(NamedTuple(packageA: String, versionA: Int32, packageB: String, versionB: Int32)),
    ) : Bool
      incompatibilities.none? do |incompatibility|
        assignment[incompatibility[:packageA]]? == incompatibility[:versionA] &&
          assignment[incompatibility[:packageB]]? == incompatibility[:versionB]
      end
    end
  end
end
