require "../../spec_helper"

describe Chiasmus::MCPServer::ToolDispatcher do
  it "returns a response channel before the work completes" do
    dispatcher = Chiasmus::MCPServer::ToolDispatcher.new(1)
    started = Channel(Bool).new(1)
    release = Channel(Bool).new(1)

    response = dispatcher.dispatch do
      started.send(true)
      release.receive
      "done"
    end

    started.receive.should be_true

    select
    when value = response.receive?
      fail("expected async dispatch, got #{value.inspect}")
    else
    end

    release.send(true)
    response.receive.should eq("done")
  end

  it "bounds concurrent tool work with semaphore slots" do
    dispatcher = Chiasmus::MCPServer::ToolDispatcher.new(1)
    first_started = Channel(Bool).new(1)
    second_started = Channel(Bool).new(1)
    release_first = Channel(Bool).new(1)

    first = dispatcher.dispatch do
      first_started.send(true)
      release_first.receive
      "first"
    end

    first_started.receive.should be_true

    second = dispatcher.dispatch do
      second_started.send(true)
      "second"
    end

    select
    when second_started.receive?
      fail("expected second task to wait for the slot")
    else
    end

    release_first.send(true)
    first.receive.should eq("first")
    second_started.receive.should be_true
    second.receive.should eq("second")
  end
end
