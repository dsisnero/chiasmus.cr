require "spec"
require "file_utils"
require "../../spec_helper"
require "../../../src/chiasmus/parity"

describe "chiasmus parity qualified_name attachment" do
  it "attaches repeated same-named qualified names in order" do
    dir = File.join(Dir.tempdir, "chiasmus-qn-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "facts.pl")
    File.write(path, <<-PL)
    defines('a.java', 'HSTEM', variable, 197, 197).
    defines('a.java', 'HSTEM', variable, 28, 28).
    qualified_name('a.java', 'HSTEM', 'Type1KeyWord.HSTEM').
    qualified_name('a.java', 'HSTEM', 'CharStringCommand.HSTEM').
    PL

    graph = Chiasmus::Parity::Structural.load_graph(path)
    graph.defines.map(&.qualified_name).should eq(["Type1KeyWord.HSTEM", "CharStringCommand.HSTEM"])
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
