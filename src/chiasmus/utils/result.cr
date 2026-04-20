module Chiasmus
  module Utils
    # Result type for better error handling and user feedback
    class Result(T)
      property value : T?
      property error : String?
      property details : Hash(String, String)

      def initialize(@value : T? = nil, @error : String? = nil, @details = {} of String => String)
      end

      def success? : Bool
        @error.nil? && !@value.nil?
      end

      def failure? : Bool
        !success?
      end

      def unwrap : T
        value = @value
        raise "Attempted to unwrap nil value: #{@error}" if value.nil?
        value
      end

      def unwrap_or(default : T) : T
        @value || default
      end

      def unwrap_or_else(&block : -> T) : T
        @value || block.call
      end

      def map(&block : T -> U) : Result(U) forall U
        value = @value
        if @error || value.nil?
          return Result(U).new(error: @error, details: @details)
        end

        Result(U).new(value: block.call(value))
      end

      def flat_map(&block : T -> Result(U)) : Result(U) forall U
        value = @value
        if @error || value.nil?
          return Result(U).new(error: @error, details: @details)
        end

        block.call(value)
      end

      def and_then(&block : T -> Result(U)) : Result(U) forall U
        flat_map(&block)
      end

      def or_else(&block : String -> Result(T)) : Result(T)
        error = @error
        error ? block.call(error) : self
      end

      def to_s(io : IO) : Nil
        if success?
          io << "Result(Success: #{@value})"
        else
          io << "Result(Error: #{@error})"
          unless @details.empty?
            io << " Details: #{@details}"
          end
        end
      end

      # Factory methods
      def self.success(value : T) : Result(T)
        new(value: value)
      end

      def self.failure(error : String, details = {} of String => String) : Result(T)
        new(error: error, details: details)
      end

      def self.from(value : T?, error : String? = nil, details = {} of String => String) : Result(T)
        if value.nil? && error.nil?
          new(error: "Unknown error", details: details)
        elsif value.nil?
          new(error: error, details: details)
        else
          new(value: value)
        end
      end

      def self.try(&block : -> T) : Result(T)
        begin
          success(block.call)
        rescue ex
          failure(ex.message.to_s)
        end
      end
    end

    # Specialized result types for common operations
    class BoolResult < Result(Bool)
      def self.success : BoolResult
        new(value: true)
      end

      def self.failure(error : String, details = {} of String => String) : BoolResult
        new(error: error, details: details)
      end
    end

    class StringResult < Result(String)
    end

    class IntResult < Result(Int32)
    end

    class ArrayResult(T) < Result(Array(T))
    end

    # Result type for batch operations with multiple results
    class BatchResult < Result(Hash(String, BoolResult))
      property metadata : Hash(String, String)

      def initialize(
        @value : Hash(String, BoolResult)? = nil,
        @error : String? = nil,
        @details = {} of String => String,
        @metadata = {} of String => String,
      )
      end

      # Count successful operations
      def success_count : Int32
        value = @value
        value ? value.count { |_, result| result.success? && result.value == true } : 0
      end

      # Count failed operations
      def failure_count : Int32
        value = @value
        value ? value.count { |_, result| result.failure? || result.value == false } : 0
      end

      # Get successful items
      def successes : Array(String)
        value = @value
        value ? value.select { |_, result| result.success? && result.value == true }.keys : [] of String
      end

      # Get failed items with errors
      def failures : Hash(String, String)
        value = @value
        return {} of String => String unless value

        result = {} of String => String
        value.each do |key, batch_result|
          if batch_result.failure?
            result[key] = batch_result.error || "Unknown error"
          elsif batch_result.value == false
            result[key] = "Operation returned false"
          end
        end
        result
      end

      # Factory methods
      def self.success(results : Hash(String, BoolResult), metadata = {} of String => String) : BatchResult
        new(value: results, metadata: metadata)
      end

      def self.failure(error : String, details = {} of String => String) : BatchResult
        new(error: error, details: details)
      end
    end
  end
end
