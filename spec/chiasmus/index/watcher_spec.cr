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

private def wait_until(timeout = 2.seconds, interval = 10.milliseconds, &condition : -> Bool) : Bool
  deadline = Time.instant + timeout
  until condition.call
    return false if Time.instant >= deadline
    sleep(interval)
  end
  true
end

describe Watcher do
  it "publishes one classified batch for changes observed in the same scan" do
    with_temp_dir do |dir|
      baseline_path = File.join(dir, "baseline.ts")
      baseline_relative = Path.new(baseline_path).relative_to(dir).to_s
      File.write(baseline_path, "baseline")
      batches = Channel(ChangeSet).new(1)
      watcher = Watcher.new(dir, interval: 0.05.seconds) { |batch| batches.send(batch) }

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?(baseline_relative) }.should be_true

        File.write(File.join(dir, "a.ts"), "a")
        File.write(File.join(dir, "b.ts"), "b")
        batch = select
        when value = batches.receive
          value
        when timeout(1.second)
          raise "watcher did not publish change batch"
        end

        batch.added.sort!.should eq(["a.ts", "b.ts"])
        batch.modified.should be_empty
        batch.deleted.should be_empty
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end

  it "detects new file creation" do
    with_temp_dir do |dir|
      baseline_path = File.join(dir, "baseline.ts")
      baseline_relative = Path.new(baseline_path).relative_to(dir).to_s
      File.write(baseline_path, "baseline")
      changes = [] of ChangeSet
      changes_lock = Mutex.new
      watcher = Watcher.new(dir, interval: 0.05.seconds) do |batch|
        changes_lock.synchronize { changes << batch }
      end

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?(baseline_relative) }.should be_true
        File.write(File.join(dir, "new_file.ts"), "hello")

        wait_until do
          changes_lock.synchronize do
            changes.any?(&.added.includes?("new_file.ts"))
          end
        end.should be_true
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end

  it "detects file modification" do
    with_temp_dir do |dir|
      path = File.join(dir, "test.ts")
      relative_path = Path.new(path).relative_to(dir).to_s
      File.write(path, "v1")
      changes = [] of ChangeSet
      changes_lock = Mutex.new
      watcher = Watcher.new(dir, interval: 0.05.seconds) do |batch|
        changes_lock.synchronize { changes << batch }
      end

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?(relative_path) }.should be_true

        File.write(path, "v2")

        wait_until do
          changes_lock.synchronize do
            changes.any?(&.modified.includes?(relative_path))
          end
        end.should be_true
      ensure
        watcher.stop
        watcher.wait
      end
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
      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?("a.ts") }.should be_true
        watcher.watched_files.should contain("a.ts")
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end

  it "excludes gitignored files from watched state" do
    with_temp_dir do |dir|
      Process.run("git", ["init", "-q", dir]).success?.should be_true
      File.write(File.join(dir, ".gitignore"), "ignored.ts\n")
      File.write(File.join(dir, "tracked.ts"), "tracked")
      File.write(File.join(dir, "ignored.ts"), "ignored")
      File.write(File.join(dir, ".hidden.ts"), "hidden")
      File.write(File.join(dir, "oversized.ts"), "x" * (FileDiscovery::MAX_FILE_SIZE + 1).to_i)

      watcher = Watcher.new(dir, interval: 0.05.seconds) { }
      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?("tracked.ts") }.should be_true

        watcher.watched_files.should contain("tracked.ts")
        watcher.watched_files.should_not contain("ignored.ts")
        watcher.watched_files.should_not contain(".hidden.ts")
        watcher.watched_files.should_not contain("oversized.ts")
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end

  it "stops promptly instead of waiting out the poll interval" do
    with_temp_dir do |dir|
      File.write(File.join(dir, "a.ts"), "a")
      watcher = Watcher.new(dir, interval: 30.seconds) { }
      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.includes?("a.ts") }.should be_true

        # Shutdown must not have to burn a whole interval before the loop exits.
        elapsed = Time.measure do
          watcher.stop
          watcher.wait
        end
        elapsed.should be < 2.seconds
      ensure
        watcher.stop
      end
    end
  end

  it "reports when a blocked scan has not stopped by the shutdown deadline" do
    with_temp_dir do |dir|
      File.write(File.join(dir, "a.ts"), "a")
      entered = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      watcher = Watcher.new(dir, interval: 0.01.seconds) do |_changes|
        entered.send(nil)
        release.receive
      end
      spawn { watcher.run }
      wait_until { watcher.watched_files.includes?("a.ts") }.should be_true
      File.write(File.join(dir, "a.ts"), "changed")
      entered.receive

      begin
        watcher.stop
        watcher.wait(20.milliseconds).should be_false
      ensure
        release.send(nil)
        watcher.wait
      end
    end
  end

  it "does not start polling when stopped before run is called" do
    with_temp_dir do |dir|
      File.write(File.join(dir, "a.ts"), "a")
      calls = 0
      watcher = Watcher.new(dir, interval: 0.01.seconds) { calls += 1 }

      watcher.stop.should be_true
      # A signal can arrive during startup, before the watcher fiber is
      # scheduled. `run` must honour the earlier stop instead of resurrecting.
      watcher.run
      watcher.wait

      calls.should eq(0)
    end
  end

  it "does not report a transient empty filesystem view as a full deletion" do
    with_temp_dir do |dir|
      paths = %w[a.ts b.ts c.ts].map { |name| File.join(dir, name) }
      paths.each { |path| File.write(path, "x") }
      batches = [] of ChangeSet
      lock = Mutex.new
      watcher = Watcher.new(dir, interval: 0.2.seconds) do |batch|
        lock.synchronize { batches << batch }
      end

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.size == 3 }.should be_true

        # Blink: remove everything and restore it well inside a single poll
        # interval, so at most one scan can observe the empty view.
        paths.each { |path| File.delete(path) }
        paths.each { |path| File.write(path, "x") }

        sleep(0.6.seconds)

        lock.synchronize { batches.any? { |batch| !batch.deleted.empty? } }.should be_false
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end

  it "still reports a deletion once the empty view is confirmed" do
    with_temp_dir do |dir|
      paths = %w[a.ts b.ts c.ts].map { |name| File.join(dir, name) }
      paths.each { |path| File.write(path, "x") }
      batches = [] of ChangeSet
      lock = Mutex.new
      watcher = Watcher.new(dir, interval: 0.05.seconds) do |batch|
        lock.synchronize { batches << batch }
      end

      begin
        spawn { watcher.run }
        wait_until { watcher.watched_files.size == 3 }.should be_true

        paths.each { |path| File.delete(path) }

        wait_until(2.seconds) do
          lock.synchronize { batches.any? { |batch| !batch.deleted.empty? } }
        end.should be_true

        lock.synchronize { batches.flat_map(&.deleted) }.sort.should eq(["a.ts", "b.ts", "c.ts"])
      ensure
        watcher.stop
        watcher.wait
      end
    end
  end
end
