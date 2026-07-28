require "../../spec_helper"
require "../../../src/chiasmus/index/directory_walk"
require "random/secure"

describe Chiasmus::Index::DirectoryWalk do
  it "skips hidden entries and does not apply gitignore rules" do
    dir = File.join(Dir.tempdir, "chiasmus-directory-walk-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "visible.cr"), "class Visible; end")
      File.write(File.join(dir, ".hidden.cr"), "class Hidden; end")
      File.write(File.join(dir, ".gitignore"), "ignored.cr\n")
      File.write(File.join(dir, "ignored.cr"), "class Ignored; end")

      paths = Chiasmus::Index::DirectoryWalk.files(dir)

      paths.should contain(File.join(dir, "visible.cr"))
      paths.should contain(File.join(dir, "ignored.cr"))
      paths.should_not contain(File.join(dir, ".hidden.cr"))
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
