require "../../spec_helper"
require "../../../src/chiasmus/utils/bounded_work"
require "tree-sitter-manager"

describe Chiasmus::Utils::BoundedWork do
  it "preserves order while respecting the concurrency bound" do
    active = 0
    peak = 0
    mutex = Mutex.new

    results = Chiasmus::Utils::BoundedWork.map_ordered([0, 1, 2, 3, 4], 2) do |value|
      mutex.synchronize do
        active += 1
        peak = {peak, active}.max
      end

      sleep 20.milliseconds
      value * 2
    ensure
      mutex.synchronize do
        active -= 1
      end
    end

    results.should eq([0, 2, 4, 6, 8])
    peak.should be <= 2
  end

  it "drains all work before raising the first error" do
    completed = 0
    mutex = Mutex.new

    expect_raises(Exception, "boom") do
      Chiasmus::Utils::BoundedWork.map_ordered_or_raise([0, 1, 2, 3], 2) do |value|
        if value == 1
          raise "boom"
        end

        sleep 40.milliseconds
        value
      ensure
        mutex.synchronize do
          completed += 1
        end
      end
    end

    completed.should eq(4)
  end

  it "streams completed work before the slowest item finishes" do
    results = Chiasmus::Utils::BoundedWork.each_result([0, 1], 2) do |value|
      sleep(value == 0 ? 80.milliseconds : 10.milliseconds)
      value * 10
    end

    first = TreeSitterManager::Timeout.with_timeout_async(40, results)
    first.should_not be_nil
    first_result = first || raise "expected first bounded work result"
    first_result.index.should eq(1)
    first_result.value.should eq(10)
    first_result.error.should be_nil

    second = results.receive?
    second.should_not be_nil
    second_result = second || raise "expected second bounded work result"
    second_result.index.should eq(0)
    second_result.value.should eq(0)
    second_result.error.should be_nil

    results.receive?.should be_nil
  end

  it "preserves ordered results when cpu-parallel mode is requested" do
    results = Chiasmus::Utils::BoundedWork.map_ordered([0, 1, 2, 3], 3, parallel: true) do |value|
      sleep(((3 - value) * 5).milliseconds)
      value * 3
    end

    results.should eq([0, 3, 6, 9])
  end
end
