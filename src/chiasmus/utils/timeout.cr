module Chiasmus
  module Utils
    # Timeout utilities for async operations
    module Timeout
      # Execute a block with a timeout
      # Returns the result or nil if timeout occurs
      def self.with_timeout(timeout_ms : Int32, &block : -> T) : T? forall T
        result_channel = Channel(T?).new
        timeout_channel = Channel(Nil).new

        # Spawn the operation
        spawn do
          begin
            result = block.call
            result_channel.send(result)
          rescue ex
            result_channel.send(nil)
          end
        end

        # Spawn the timeout
        spawn do
          sleep timeout_ms.milliseconds
          timeout_channel.send(nil)
        end

        # Wait for either result or timeout
        select
        when result = result_channel.receive
          return result
        when timeout_channel.receive
          return nil
        end
      end

      # Execute an async operation (Channel-based) with timeout
      # Returns the result or nil if timeout occurs
      def self.with_timeout_async(timeout_ms : Int32, channel : Channel(T)) : T? forall T
        timeout_channel = Channel(Nil).new

        # Spawn the timeout
        spawn do
          sleep timeout_ms.milliseconds
          timeout_channel.send(nil)
        end

        # Wait for either result or timeout
        select
        when result = channel.receive
          return result
        when timeout_channel.receive
          return nil
        end
      end

      # Create a channel that times out after specified duration
      def self.timeout_channel(timeout_ms : Int32) : Channel(Nil)
        channel = Channel(Nil).new

        spawn do
          sleep timeout_ms.milliseconds
          channel.send(nil)
        end

        channel
      end
    end
  end
end
