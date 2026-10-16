require "process"

module GrammarCompiler
  C_COMPILERS = {"cc", "gcc", "clang"}

  def self.available_c_compiler?(path : String? = ENV["PATH"]?) : Bool
    C_COMPILERS.any? { |compiler| Process.find_executable(compiler, path) }
  end
end
