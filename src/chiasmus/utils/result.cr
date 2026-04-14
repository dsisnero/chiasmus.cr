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
        if @value.nil?
          raise "Attempted to unwrap nil value: #{@error}"
        end
        @value.not_nil!
      end

      def unwrap_or(default : T) : T
        @value || default
      end

      def unwrap_or_else(&block : -> T) : T
        @value || block.call
      end

      def map(&block : T -> U) : Result(U) forall U
        if success?
          Result(U).new(value: block.call(@value.not_nil!))
        else
          Result(U).new(error: @error, details: @details)
        end
      end

      def flat_map(&block : T -> Result(U)) : Result(U) forall U
        if success?
          block.call(@value.not_nil!)
        else
          Result(U).new(error: @error, details: @details)
        end
      end

      def and_then(&block : T -> Result(U)) : Result(U) forall U
        flat_map(&block)
      end

      def or_else(&block : String -> Result(T)) : Result(T)
        if failure?
          block.call(@error.not_nil!)
        else
          self
        end
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
  end
end
