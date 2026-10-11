require "spec"
require "file_utils"
require "../../spec_helper"
require "../../../src/chiasmus/parity"

describe "chiasmus parity signature facts" do
  it "loads signature facts and attaches them to definitions" do
    dir = File.join(Dir.tempdir, "chiasmus-signature-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "facts.pl")
    File.write(path, <<-PL)
    defines('src/a.java', 'add', method, 1, 2).
    signature('src/a.java', 'add', '(int a, int b) -> int').
    qualified_name('src/a.java', 'add', 'Calc.add').
    PL

    graph = Chiasmus::Parity::Structural.load_graph(path)
    fact = graph.defines.find(&.name.==("add"))
    fact.should_not be_nil
    (fact || raise "expected add").signature.should eq("(int a, int b) -> int")
    (fact || raise "expected add").qualified_name.should eq("Calc.add")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
