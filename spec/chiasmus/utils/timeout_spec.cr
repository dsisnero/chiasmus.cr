require "../../spec_helper"
require "../../../src/chiasmus/utils/timeout"

describe Chiasmus::Utils::Timeout do
  it "returns nil when an async channel closes before producing a value" do
    channel = Channel(Int32).new(1)
    channel.close

    result = Chiasmus::Utils::Timeout.with_timeout_async(50, channel)

    result.should be_nil
  end

  it "returns the async value before the timeout expires" do
    channel = Channel(Int32).new(1)

    spawn do
      sleep 10.milliseconds
      channel.send(42)
      channel.close
    end

    result = Chiasmus::Utils::Timeout.with_timeout_async(50, channel)

    result.should eq(42)
  end
end
