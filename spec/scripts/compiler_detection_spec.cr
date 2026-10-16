require "../spec_helper"
require "../../scripts/compiler_detection"

describe "GrammarCompiler" do
  it "finds a C compiler in an explicit PATH on every platform" do
    dir = File.join(Dir.tempdir, "chiasmus-compiler-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      compiler = File.join(dir, {% if flag?(:windows) %} "clang.exe" {% else %} "clang" {% end %})
      File.write(compiler, "")
      File.chmod(compiler, 0o755)

      GrammarCompiler.available_c_compiler?(dir).should be_true
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns false when PATH has no C compiler" do
    dir = File.join(Dir.tempdir, "chiasmus-compiler-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      GrammarCompiler.available_c_compiler?(dir).should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
