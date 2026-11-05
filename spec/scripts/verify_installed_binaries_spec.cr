require "../spec_helper"

describe "installed binary verification" do
  it "accepts working CLIs and rejects any failed help command" do
    dir = File.tempname("chiasmus-install-probe")
    Dir.mkdir_p(dir)
    names = %w[chiasmus chiasmus-grammar chiasmus-discover chiasmus-facts chiasmus-agent]
    probe = File.join(Dir.current, "scripts", "verify_installed_binaries.sh")

    begin
      names.each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\nexit 0\n")
        File.chmod(path, 0o755)
      end
      Process.run("sh", [probe, dir]).success?.should be_true

      File.write(File.join(dir, "chiasmus-facts"), "#!/bin/sh\nexit 127\n")
      Process.run("sh", [probe, dir], output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
