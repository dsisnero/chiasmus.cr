require "../types"

module Chiasmus
  module Graph
    module Walkers
      def with_scope(scope_stack : Array(String), name : String, & : -> Nil) : Nil
        scope_stack << name
        yield
      ensure
        scope_stack.pop
      end

      def record_call(
        caller : String?,
        callee : String?,
        calls : Array(CallsFact),
        call_set : Set(String),
      ) : Nil
        return unless caller && callee

        key = "#{caller}->#{callee}"
        return if call_set.includes?(key)

        call_set.add(key)
        calls << CallsFact.new(caller: caller, callee: callee)
      end

      def extract_string_content(node : TreeSitter::Node, source : String) : String?
        node.children.each do |child|
          if child.type == "string_fragment"
            return child.text(source)
          end
        end

        text = node.text(source)
        if (text.starts_with?("'") && text.ends_with?("'")) || (text.starts_with?('"') && text.ends_with?('"'))
          text[1...-1]
        else
          text
        end
      end
    end
  end
end
