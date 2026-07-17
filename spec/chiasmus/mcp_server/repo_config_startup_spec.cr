require "../../spec_helper"
require "file_utils"

private def with_repo_config_startup_tmp_dir(&)
  dir = File.join(Dir.tempdir, "chiasmus-repo-config-startup-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_repo_current_dir(path : String, &)
  original = Dir.current
  Dir.cd(path)
  begin
    yield
  ensure
    Dir.cd(original)
  end
end

describe "Repo config startup" do
  it "creates the repo config directory on server initialization without seeding parity config" do
    with_repo_config_startup_tmp_dir do |repo_root|
      temp_home = File.join(Dir.tempdir, "chiasmus-home-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(temp_home)

      begin
        with_env({"CHIASMUS_HOME" => temp_home}) do
          with_repo_current_dir(repo_root) do
            server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new

            begin
              config_dir = Chiasmus::Utils::Config.repo_config_dir(repo_root)
              config_path = Chiasmus::Utils::Config.repo_config_path(repo_root)

              Dir.exists?(config_dir).should be_true
              File.exists?(config_path).should be_false

              config = Chiasmus::Utils::Config.load_repo_config(repo_root)
              config.parity.should be_nil
            ensure
              server.skill_library.close rescue nil
            end
          end
        end
      ensure
        FileUtils.rm_rf(temp_home)
      end
    end
  end
end
