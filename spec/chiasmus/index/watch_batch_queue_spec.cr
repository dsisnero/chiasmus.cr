require "spec"
require "../../../src/chiasmus/index/watch_batch_queue"
require "../../../src/chiasmus/index/watcher"

include Chiasmus::Index

private def change_set(added = [] of String, modified = [] of String, deleted = [] of String) : ChangeSet
  ChangeSet.new(added, modified, deleted)
end

describe WatchBatchQueue do
  it "runs one batch at a time and merges the change sets that arrive while it runs" do
    batches = Channel(ChangeSet).new(4)
    release = Channel(Nil).new(1)

    queue = WatchBatchQueue.new do |changes|
      batches.send(changes)
      release.receive
    end

    queue.submit(change_set(added: ["a.cr"]))
    first = batches.receive

    # These arrive while the first batch is blocked in the handler.
    queue.submit(change_set(added: ["b.cr"]))
    queue.submit(change_set(deleted: ["a.cr"]))
    queue.submit(change_set(modified: ["c.cr"]))

    release.send(nil)

    second = batches.receive
    release.send(nil)

    first.added.should eq(["a.cr"])

    # The deleted path is reported once, even though it was added earlier.
    second.added.should eq(["b.cr"])
    second.modified.should eq(["c.cr"])
    second.deleted.should eq(["a.cr"])
  end

  it "stops accepting work once draining starts" do
    ran = Channel(Nil).new(1)
    queue = WatchBatchQueue.new { |_changes| ran.send(nil) }

    queue.close_and_drain
    queue.closing?.should be_true

    queue.submit(change_set(added: ["late.cr"]))

    select
    when ran.receive
      fail "handler ran after shutdown"
    when timeout(100.milliseconds)
    end
  end

  it "drains an in-flight batch before returning" do
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    finished = Channel(Nil).new(1)

    queue = WatchBatchQueue.new do |_changes|
      entered.send(nil)
      release.receive
      finished.send(nil)
    end

    queue.submit(change_set(added: ["a.cr"]))
    entered.receive

    drained = Channel(Nil).new(1)
    spawn do
      queue.close_and_drain
      drained.send(nil)
    end

    select
    when drained.receive
      fail "drain returned while a batch was still running"
    when timeout(100.milliseconds)
    end

    release.send(nil)
    finished.receive
    drained.receive
  end

  it "reports an unfinished batch when the shutdown deadline expires" do
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    queue = WatchBatchQueue.new(20.milliseconds) do |_changes|
      entered.send(nil)
      release.receive
    end

    queue.submit(change_set(added: ["slow.cr"]))
    entered.receive
    begin
      queue.close_and_drain.should be_false
    ensure
      release.send(nil)
    end
  end

  it "keeps draining after a batch raises" do
    batches = Channel(ChangeSet).new(2)
    call_count = Atomic(Int32).new(0)

    queue = WatchBatchQueue.new do |changes|
      if call_count.add(1).zero?
        batches.send(changes)
        raise "boom"
      end

      batches.send(changes)
    end

    queue.submit(change_set(added: ["a.cr"]))
    first = batches.receive
    first.added.should eq(["a.cr"])

    queue.submit(change_set(added: ["b.cr"]))
    second = batches.receive
    second.added.should eq(["b.cr"])
  end
end

describe ChangeSet do
  it "folds a delete followed by a re-add into an add" do
    first = change_set(deleted: ["gone.cr"])
    second = change_set(added: ["gone.cr"])

    merged = first.merge(second)

    merged.added.should eq(["gone.cr"])
    merged.modified.should be_empty
    merged.deleted.should be_empty
  end

  it "folds an add followed by a delete into a delete" do
    first = change_set(added: ["temporary.cr"])
    second = change_set(deleted: ["temporary.cr"])

    merged = first.merge(second)

    merged.added.should be_empty
    merged.modified.should be_empty
    merged.deleted.should eq(["temporary.cr"])
  end

  it "keeps untouched paths and reports its total size" do
    merged = change_set(added: ["a.cr"]).merge(change_set(modified: ["b.cr"], deleted: ["c.cr"]))

    merged.added.should eq(["a.cr"])
    merged.modified.should eq(["b.cr"])
    merged.deleted.should eq(["c.cr"])
    merged.size.should eq(3)
  end
end
