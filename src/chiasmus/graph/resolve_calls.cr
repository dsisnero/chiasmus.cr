# Ported from vendor/chiasmus/src/graph/resolve-calls.ts (MIT, pi-code-graph)
#
# Project-wide qualified-name resolution for TS/JS call graphs.
# Combines per-file class field maps into a project registry, then walks
# each pending call's receiver chain to compute a `Class.method` QN.

require "./types"

module Chiasmus
  module Graph
    JS_BUILTIN_TYPES = Set{
      "any", "unknown", "never", "void", "object",
      "string", "number", "boolean", "bigint", "symbol", "undefined", "null",
      "Array", "Map", "Set", "WeakMap", "WeakSet",
      "Promise", "Error", "TypeError", "RangeError", "SyntaxError",
      "Date", "RegExp", "Function", "Object", "String", "Number", "Boolean",
      "Symbol", "BigInt",
      "Int8Array", "Uint8Array", "Uint8ClampedArray",
      "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
      "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
      "ArrayBuffer", "SharedArrayBuffer", "DataView",
      "Buffer", "URL", "URLSearchParams",
      "JSON", "Math", "Reflect", "Proxy", "Intl",
      "console", "process",
      "ReadonlySet", "ReadonlyMap", "ReadonlyArray", "Iterable", "IterableIterator",
      "AsyncIterable", "AsyncIterableIterator",
    }

    module CallResolver
      extend self

      # --- ClassFieldRegistry ---

      def build_class_field_registry(per_file : Array(FileTypeInfo)) : Hash(String, Hash(String, String))
        own_fields = Hash(String, Hash(String, String)).new
        parents = Hash(String, String).new

        per_file.each do |info|
          info.class_fields.each do |class_field|
            existing = own_fields[class_field.class_name]?
            unless existing
              existing = Hash(String, String).new
              own_fields[class_field.class_name] = existing
            end
            class_field.fields.each { |field_name, field_type| existing[field_name] = field_type }
          end
          if extends = info.class_extends
            extends.each { |ext| parents[ext.class_name] = ext.parent }
          end
        end

        resolved = Hash(String, Hash(String, String)).new
        in_progress = Set(String).new

        resolve = uninitialized Proc(String, Hash(String, String))
        resolve = ->(class_name : String) : Hash(String, String) {
          if cached = resolved[class_name]?
            return cached
          end
          if in_progress.includes?(class_name)
            return own_fields[class_name]? || Hash(String, String).new
          end
          in_progress << class_name

          merged = Hash(String, String).new
          if parent = parents[class_name]?
            resolve.call(parent).each { |field_name, field_type| merged[field_name] = field_type }
          end
          if own = own_fields[class_name]?
            own.each { |field_name, field_type| merged[field_name] = field_type }
          end

          in_progress.delete(class_name)
          resolved[class_name] = merged
          merged
        }

        class_names = Set(String).new
        own_fields.each_key { |class_name| class_names << class_name }
        parents.each_key { |class_name| class_names << class_name }
        parents.each_value { |class_name| class_names << class_name }
        class_names.each { |class_name| resolve.call(class_name) }

        resolved
      end

      # --- ClassMethodRegistry ---

      def build_class_method_registry(
        per_file : Array(FileTypeInfo),
        extra_contains_methods : Array({parent: String, child: String})? = nil,
      ) : ClassMethodRegistry
        own = Hash(String, Set(String)).new
        parents = Hash(String, String).new

        per_file.each do |info|
          if class_methods = info.class_methods
            class_methods.each do |class_method|
              existing = own[class_method.class_name]?
              unless existing
                existing = Set(String).new
                own[class_method.class_name] = existing
              end
              class_method.methods.each { |method_name| existing << method_name }
            end
          end
          if extends = info.class_extends
            extends.each { |ext| parents[ext.class_name] = ext.parent }
          end
        end

        if extra = extra_contains_methods
          extra.each do |contains_method|
            existing = own[contains_method[:parent]]? || Set(String).new
            existing << contains_method[:child]
            own[contains_method[:parent]] = existing
          end
        end

        flat = Hash(String, Set(String)).new
        in_progress = Set(String).new

        resolve = uninitialized Proc(String, Set(String))
        resolve = ->(class_name : String) : Set(String) {
          if cached = flat[class_name]?
            return cached
          end
          if in_progress.includes?(class_name)
            return own[class_name]? || Set(String).new
          end
          in_progress << class_name

          merged = Set(String).new
          if parent = parents[class_name]?
            resolve.call(parent).each { |method_name| merged << method_name }
          end
          if s = own[class_name]?
            s.each { |method_name| merged << method_name }
          end

          in_progress.delete(class_name)
          flat[class_name] = merged
          merged
        }

        class_names = Set(String).new
        own.each_key { |class_name| class_names << class_name }
        parents.each_key { |class_name| class_names << class_name }
        parents.each_value { |class_name| class_names << class_name }
        class_names.each { |class_name| resolve.call(class_name) }

        ClassMethodRegistry.new(flat: flat, own: own, parents: parents)
      end

      # --- resolveChain (resolve receiver chain → final type) ---

      private def resolve_chain(
        pending : PendingCall,
        registry : Hash(String, Hash(String, String)),
      ) : String?
        chain = pending.receiver_chain
        return nil if chain.empty?

        head = chain[0]
        current_type = if head == "this" || head == "self"
                         pending.enclosing_class
                       else
                         pending.var_types[head]?
                       end
        return nil unless current_type

        (1...chain.size).each do |chain_index|
          field_name = chain[chain_index]
          fields = registry[current_type]?
          return nil unless fields
          next_type = fields[field_name]?
          return nil unless next_type
          current_type = next_type
        end

        current_type
      end

      # --- buildMethodOwnerIndex ---

      private def build_method_owner_index(graph : CodeGraph) : Hash(String, Set(String))
        by_method = Hash(String, Set(String)).new
        method_names = Set(String).new
        graph.defines.each { |definition| method_names << definition.name if definition.kind.method? }
        graph.contains.each do |contains_fact|
          next unless method_names.includes?(contains_fact.child)
          set = by_method[contains_fact.child]? || Set(String).new
          set << contains_fact.parent
          by_method[contains_fact.child] = set
        end
        by_method
      end

      # --- resolveCallsWithRegistry (main entry point) ---

      # Returns resolved QNs as Hash(caller\0callee → Class.method), applying
      # the same matching rules as the upstream (first unset row wins).
      def resolve_calls_with_registry(
        graph : CodeGraph,
        registry : Hash(String, Hash(String, String)),
        method_registry : ClassMethodRegistry? = nil,
      ) : Hash(String, String)
        results = Hash(String, String).new
        type_info = graph.type_info
        return results if type_info.nil? || type_info.empty?

        # Build call index: (caller, callee) → resolved flags
        matched = Set(String).new

        method_owners = build_method_owner_index(graph)
        methods = method_registry || build_class_method_registry(
          type_info,
          method_contains_facts(graph),
        )

        find_declaring_class = ->(start_type : String, method : String) : String? {
          seen = Set(String).new
          cur = start_type
          while cur && !seen.includes?(cur)
            seen << cur
            if own_set = methods.own[cur]?
              return cur if own_set.includes?(method)
            end
            cur = methods.parents[cur]?
          end
        }

        type_info.each do |info|
          info.pending_calls.each do |pending|
            final_type = resolve_chain(pending, registry)
            if final_type && JS_BUILTIN_TYPES.includes?(final_type)
              final_type = nil
            end
            qn : String? = nil

            if final_type
              known = methods.flat[final_type]?
              if known && known.includes?(pending.callee)
                declarer = find_declaring_class.call(final_type, pending.callee) || final_type
                qn = "#{declarer}.#{pending.callee}"
              end
            end

            unless qn
              owners = method_owners[pending.callee]?
              if owners && owners.size == 1
                qn = "#{owners.first}.#{pending.callee}"
              end
            end

            unless qn
              typed_owner = find_owner_via_methods(pending.callee, methods.flat)
              qn = "#{typed_owner}.#{pending.callee}" if typed_owner
            end

            next unless qn

            key = "#{pending.caller}\0#{pending.callee}"
            next if matched.includes?(key)
            matched << key
            results[key] = qn.not_nil!
          end
        end

        results
      end

      # --- methodContainsFacts ---

      private def method_contains_facts(graph : CodeGraph) : Array({parent: String, child: String})
        out = [] of {parent: String, child: String}
        method_names = Set(String).new
        graph.defines.each { |definition| method_names << definition.name if definition.kind.method? }
        graph.contains.each do |contains_fact|
          if method_names.includes?(contains_fact.child)
            out << {parent: contains_fact.parent, child: contains_fact.child}
          end
        end
        out
      end

      # --- findOwnerViaMethods ---

      private def find_owner_via_methods(
        method : String,
        flat : Hash(String, Set(String)),
      ) : String?
        sole : String? = nil
        flat.each do |class_name, set|
          next unless set.includes?(method)
          return nil if sole
          sole = class_name
        end
        sole
      end
    end
  end
end
