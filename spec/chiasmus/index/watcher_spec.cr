require "spec"
require "file_utils"
require "../../../src/chiasmus/index/watcher"

include Chiasmus::Index

private def with_temp_dir(& : String ->)
  dir = File.tempname("chiasmus-watcher-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) rescue nil
  end
end

describe Watcher do
  it "detects new file creation" do
    with_temp_dir do |dir|
      changed = [] of String
      watcher = Watcher.new(dir, interval: 0.05.seconds) { |p| changed << p }
      spawn { watcher.run }
      sleep(0.15.seconds)
      File.write(File.join(dir, "new_file.ts"), "hello")
      sleep(0.15.seconds)
      watcher.stop
      sleep(0.05.seconds)
      changed.any?(&.ends_with?("new_file.ts")).should be_true
    end
  end

  it "detects file modification" do
    with_temp_dir do |dir|
      path = File.join(dir, "test.ts")
      File.write(path, "v1")
      changed = [] of String
      watcher = Watcher.new(dir, interval: 0.05.seconds) { |p| changed << p }
      spawn { watcher.run }
      sleep(0.15.seconds)
      File.write(path, "v2")
      sleep(0.15.seconds)
      watcher.stop
      sleep(0.05.seconds)
      changed.any?(&.ends_with?("test.ts")).should be_true
    end
  end

  it "stops cleanly" do
    with_temp_dir do |dir|
      watcher = Watcher.new(dir, interval: 0.05.seconds) { }
      spawn { watcher.run }
      sleep(0.1.seconds)
      watcher.stop.should be_true
    end
  end

  it "exposes watched files" do
    with_temp_dir do |dir|
      File.write(File.join(dir, "a.ts"), "a")
      watcher = Watcher.new(dir, interval: 0.05.seconds) { }
      spawn { watcher.run }
      sleep(0.15.seconds)
      watcher.stop
      watcher.watched_files.should contain("a.ts")
    end
  end
end
