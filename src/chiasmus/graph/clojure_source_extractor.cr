require "./types"

module Chiasmus
  module Graph
    module ClojureSourceExtractor
      extend self

      private enum FormKind
        List
        Vector
        Symbol
      end

      private record Token, text : String, line : Int32

      private class Form
        getter kind, text, children, line

        def initialize(@kind : FormKind, @text : String?, @children : Array(Form), @line : Int32)
        end

        def self.symbol(text : String, line : Int32) : Form
          new(FormKind::Symbol, text, [] of Form, line)
        end

        def self.list(children : Array(Form), line : Int32) : Form
          new(FormKind::List, nil, children, line)
        end

        def self.vector(children : Array(Form), line : Int32) : Form
          new(FormKind::Vector, nil, children, line)
        end

        def list? : Bool
          @kind == FormKind::List
        end

        def vector? : Bool
          @kind == FormKind::Vector
        end

        def symbol? : Bool
          @kind == FormKind::Symbol
        end
      end

      private class Parser
        def initialize(@tokens : Array(Token))
          @index = 0
        end

        def parse_forms : Array(Form)
          forms = [] of Form

          while @index < @tokens.size
            if form = parse_form
              forms << form
            end
          end

          forms
        end

        private def parse_form : Form?
          token = @tokens[@index]
          @index += 1

          case token.text
          when "("
            parse_compound(")", token.line, FormKind::List)
          when "["
            parse_compound("]", token.line, FormKind::Vector)
          when ")", "]"
            nil
          else
            Form.symbol(token.text, token.line)
          end
        end

        private def parse_compound(terminator : String, line : Int32, kind : FormKind) : Form
          children = [] of Form

          while @index < @tokens.size
            break if @tokens[@index].text == terminator

            if child = parse_form
              children << child
            end
          end

          @index += 1 if @index < @tokens.size && @tokens[@index].text == terminator
          kind == FormKind::List ? Form.list(children, line) : Form.vector(children, line)
        end
      end

      private class Tokenizer
        getter tokens

        def initialize(@source : String)
          @tokens = [] of Token
          @current = [] of Char
          @line = 1
          @token_line = 1
          @in_string = false
          @escaped = false
          @in_comment = false
        end

        def run : Array(Token)
          @source.each_char { |char| consume(char) }
          flush_token
          @tokens
        end

        private def consume(char : Char) : Nil
          if @in_comment
            consume_comment(char)
          elsif @in_string
            consume_string(char)
          else
            consume_default(char)
          end
        end

        private def consume_comment(char : Char) : Nil
          return unless char == '\n'

          @in_comment = false
          @line += 1
        end

        private def consume_string(char : Char) : Nil
          if char == '"' && !@escaped
            @in_string = false
            @current.clear
            return
          end

          @line += 1 if char == '\n'
          @escaped = char == '\\' && !@escaped
          @escaped = false unless char == '\\'
        end

        private def consume_default(char : Char) : Nil
          case char
          when ';'
            start_comment
          when '"'
            start_string
          when '(', ')', '[', ']'
            push_delimiter(char)
          when ' ', '\t', '\r'
            flush_token
          when '\n'
            flush_token
            @line += 1
          else
            append_char(char)
          end
        end

        private def start_comment : Nil
          flush_token
          @in_comment = true
        end

        private def start_string : Nil
          flush_token
          @token_line = @line
          @current << '"'
          @in_string = true
        end

        private def push_delimiter(char : Char) : Nil
          flush_token
          @tokens << Token.new(char.to_s, @line)
        end

        private def append_char(char : Char) : Nil
          @token_line = @line if @current.empty?
          @current << char
        end

        private def flush_token : Nil
          return if @current.empty?

          @tokens << Token.new(@current.join, @token_line)
          @current.clear
        end
      end

      def extract(file : SourceFile) : CodeGraph
        forms = parse_forms(file.content)
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        call_set = Set(String).new

        forms.each do |form|
          next unless form.list?

          next if extract_ns(form, file.path, imports)

          if defn = defn_name(form)
            defines << DefinesFact.new(
              file: file.path,
              name: defn[:name],
              kind: SymbolKind::Function,
              line: form.line
            )
            exports << ExportsFact.new(file: file.path, name: defn[:name]) unless defn[:private]
          end
        end

        forms.each do |form|
          next unless form.list?

          defn = defn_name(form)
          next unless defn

          extract_calls(form, defn[:name], calls, call_set)
        end

        CodeGraph.new(defines: defines, calls: calls, imports: imports, exports: exports)
      end

      private def parse_forms(source : String) : Array(Form)
        tokens = tokenize(source)
        Parser.new(tokens).parse_forms
      end

      private def tokenize(source : String) : Array(Token)
        Tokenizer.new(source).run
      end

      private def symbol_text(form : Form?) : String?
        return nil unless form && form.symbol?

        form.text
      end

      private def head_symbol(form : Form) : String?
        symbol_text(form.children.first?)
      end

      private def defn_name(form : Form) : NamedTuple(name: String, private: Bool)?
        head = head_symbol(form)
        return nil unless head == "defn" || head == "defn-"

        name = symbol_text(form.children[1]?)
        return nil unless name

        {name: name, private: head == "defn-"}
      end

      private def extract_ns(form : Form, file_path : String, imports : Array(ImportsFact)) : Bool
        return false unless head_symbol(form) == "ns"

        form.children.each do |child|
          next unless child.list?
          next unless head_symbol(child) == ":require"

          child.children.each do |require_form|
            next unless require_form.vector?

            if namespace = symbol_text(require_form.children.first?)
              imports << ImportsFact.new(file: file_path, name: namespace, source: namespace)
            end
          end
        end

        true
      end

      private def extract_calls(form : Form, enclosing_fn : String, calls : Array(CallsFact), call_set : Set(String)) : Nil
        form.children.each do |child|
          next unless child.list?

          if callee = head_symbol(child)
            normalized = normalize_callee(callee)
            if normalized && normalized != enclosing_fn
              key = "#{enclosing_fn}->#{normalized}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << CallsFact.new(caller: enclosing_fn, callee: normalized)
              end
            end
          end

          extract_calls(child, enclosing_fn, calls, call_set)
        end
      end

      private def normalize_callee(callee : String) : String?
        return nil if callee.empty? || callee.starts_with?(":")

        callee.includes?("/") ? callee.split("/").last : callee
      end
    end
  end
end
