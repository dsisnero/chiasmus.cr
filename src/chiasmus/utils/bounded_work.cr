require "./execution_pool"

module Chiasmus
  module Utils
    module BoundedWork
      extend self

      DEFAULT_MAX_CONCURRENT = {System.cpu_count, 1}.max

      record ResultEnvelope(T),
        index : Int32,
        value : T? = nil,
        error : Exception? = nil

      def each_result(
        items : Array(T),
        max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
        parallel : Bool = false,
        &block : T -> U
      ) : Channel(ResultEnvelope(U)) forall T, U
        results = Channel(ResultEnvelope(U)).new(items.size)
        return close_result_channel(results) if items.empty?

        worker_count = Math.max(1, Math.min(max_concurrent, items.size))
        slots = Channel(Bool).new(worker_count)
        done = Channel(Bool).new(items.size)

        items.each_with_index do |item, index|
          spawn_worker(parallel, worker_count) do
            slots.send(true)
            begin
              results.send(ResultEnvelope(U).new(index: index, value: block.call(item)))
            rescue ex
              results.send(ResultEnvelope(U).new(index: index, error: ex))
            ensure
              slots.receive?
              done.send(true)
            end
          end
        end

        spawn do
          items.size.times { done.receive? }
          results.close
        end

        results
      end

      def map_ordered(
        items : Array(T),
        max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
        parallel : Bool = false,
        &block : T -> U
      ) : Array(U?) forall T, U
        results, _ = collect_results(items, max_concurrent, parallel) do |item|
          block.call(item)
        end

        results
      end

      def map_ordered_or_raise(
        items : Array(T),
        max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
        parallel : Bool = false,
        &block : T -> U
      ) : Array(U) forall T, U
        results, first_error = collect_results(items, max_concurrent, parallel) do |item|
          block.call(item)
        end

        raise first_error if first_error

        results.map { |value| value || raise "bounded work lost a result" }
      end

      private def collect_results(items : Array(T), max_concurrent : Int32, parallel : Bool, &block : T -> U) : {Array(U?), Exception?} forall T, U
        return {[] of U?, nil} if items.empty?

        ordered = Array(U?).new(items.size, nil)
        first_error = nil.as(Exception?)

        results = each_result(items, max_concurrent, parallel: parallel) do |item|
          block.call(item)
        end

        while result = results.receive?
          if error = result.error
            first_error ||= error
          else
            ordered[result.index] = result.value
          end
        end

        {ordered, first_error}
      end

      private def close_result_channel(results : Channel(ResultEnvelope(U))) : Channel(ResultEnvelope(U)) forall U
        results.close
        results
      end

      private def spawn_worker(parallel : Bool, worker_count : Int32, &block : ->) : Fiber
        if parallel
          ExecutionPool.spawn_cpu(workers: worker_count) { block.call }
        else
          spawn { block.call }
        end
      end
    end
  end
end
