require "../types"
require "../tree_sitter_extensions"

module Chiasmus
  module Graph
    module Walkers
      private def clj_sym_name(node : TreeSitter::Node, source : String) : String?
        return node.text(source) if node.type == "sym_name"
        if node.type == "sym_lit"
          node.children.each do |child|
            if child.type == "sym_name"
              return child.text(source)
            end
          end
        end
        nil
      end

      private def clj_defn_name(list_node : TreeSitter::Node, source : String) : NamedTuple(name: String, private: Bool)?
        sym_idx = -1
        list_node.children.each_with_index do |child, i|
          if child.type == "sym_lit"
            sym_idx = i
            break
          end
        end
        return nil if sym_idx < 0

        head = clj_sym_name(list_node.children_array[sym_idx], source)
        return nil unless head == "defn" || head == "defn-"

        children_arr = list_node.children_array
        (sym_idx + 1...children_arr.size).each do |i|
          child = children_arr[i]
          if child.type == "sym_lit"
            if name = clj_sym_name(child, source)
              return {name: name, private: head == "defn-"}
            end
          end
        end
        nil
      end

      private def clj_extract_ns(
        list_node : TreeSitter::Node,
        source : String,
        file_path : String,
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
      ) : String?
        sym_idx = -1
        list_node.children.each_with_index do |child, i|
          if child.type == "sym_lit"
            sym_idx = i
            break
          end
        end
        return nil if sym_idx < 0

        head = clj_sym_name(list_node.children_array[sym_idx], source)
        return nil unless head == "ns"

        ns_name = nil
        children_arr = list_node.children_array
        (sym_idx + 1...children_arr.size).each do |i|
          child = children_arr[i]
          if child.type == "sym_lit"
            ns_name = clj_sym_name(child, source)
            break
          end
        end

        list_node.children.each do |child|
          next unless child.type == "list_lit"

          child.children.each do |kwd|
            if kwd.type == "kwd_lit"
              kwd_name_node = kwd.children.find { |child_node| child_node.type == "kwd_name" }
              if kwd_name_node && kwd_name_node.text(source) == "require"
                child.children.each do |vec|
                  next unless vec.type == "vec_lit"

                  vec.children.each do |sym|
                    if sym.type == "sym_lit"
                      if req_ns = clj_sym_name(sym, source)
                        imports << ImportsFact.new(file: file_path, name: req_ns, source: req_ns)
                      end
                      break
                    end
                  end
                end
              end
              break
            end
          end
        end

        ns_name
      end

      def walk_clojure(
        root_node : TreeSitter::Node,
        source : String,
        file_path : String,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        call_set : Set(String),
      ) : Nil
        defn_names = Set(String).new

        root_node.children.each do |child|
          next unless child.type == "list_lit"

          if clj_extract_ns(child, source, file_path, imports, exports)
            next
          end

          if defn = clj_defn_name(child, source)
            defines << DefinesFact.new(
              file: file_path,
              name: defn[:name],
              kind: SymbolKind::Function,
              line: child.start_point.row.to_i + 1
            )
            defn_names.add(defn[:name])
            unless defn[:private]
              exports << ExportsFact.new(file: file_path, name: defn[:name])
            end
          end
        end

        root_node.children.each do |child|
          next unless child.type == "list_lit"

          defn = clj_defn_name(child, source)
          next unless defn

          clj_extract_calls(child, source, defn[:name], calls, call_set, defn_names)
        end
      end

      private def clj_extract_calls(
        node : TreeSitter::Node,
        source : String,
        enclosing_fn : String,
        calls : Array(CallsFact),
        call_set : Set(String),
        skip_self : Set(String)?,
      ) : Nil
        node.children.each do |child|
          if child.type == "list_lit"
            child.children.each do |maybe_call|
              if maybe_call.type == "sym_lit"
                if callee = clj_sym_name(maybe_call, source)
                  if callee != enclosing_fn && (!skip_self || !skip_self.includes?(callee))
                    if callee.includes?("/")
                      callee = callee.split("/").last
                    end
                    key = "#{enclosing_fn}->#{callee}"
                    unless call_set.includes?(key)
                      call_set.add(key)
                      calls << CallsFact.new(caller: enclosing_fn, callee: callee)
                    end
                  end
                end
                break
              end
            end

            clj_extract_calls(child, source, enclosing_fn, calls, call_set, skip_self)
          end
        end
      end
    end
  end
end
