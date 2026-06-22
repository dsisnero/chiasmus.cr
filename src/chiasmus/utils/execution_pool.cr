module Chiasmus
  module Utils
    module ExecutionPool
      extend self

      DEFAULT_CPU_WORKERS = {System.cpu_count, 1}.max

      {% if flag?(:execution_context) %}
        @@cpu_mutex = Mutex.new
        @@cpu_context = nil.as(Fiber::ExecutionContext::Parallel?)

        def cpu_parallel_available? : Bool
          true
        end

        def spawn_cpu(name : String? = nil, workers : Int32 = DEFAULT_CPU_WORKERS, &block : ->) : Fiber
          context = ensure_cpu_context(workers)
          context.spawn(name: name) { block.call }
        end

        private def ensure_cpu_context(workers : Int32) : Fiber::ExecutionContext::Parallel
          requested = Math.max(1, workers)

          @@cpu_mutex.synchronize do
            context = @@cpu_context
            unless context
              context = Fiber::ExecutionContext::Parallel.new("chiasmus-cpu", requested)
              @@cpu_context = context
              return context
            end

            if context.capacity < requested
              context.resize(requested)
            end

            context
          end
        end
      {% else %}
        def cpu_parallel_available? : Bool
          false
        end

        def spawn_cpu(name : String? = nil, workers : Int32 = DEFAULT_CPU_WORKERS, &block : ->) : Fiber
          spawn(name: name) { block.call }
        end
      {% end %}
    end
  end
end
