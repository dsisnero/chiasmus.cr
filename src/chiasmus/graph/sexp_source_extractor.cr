require "./types"

# A small source-form extractor for the Lisp-family grammars.  It deliberately
# owns the fallback contract rather than depending on a particular grammar's
# node names: users still get useful graphs while a native grammar is being
# installed by tree-sitter-manager.
module Chiasmus
  module Graph
    module SexpSourceExtractor
      extend self

      private enum Kind
        List
        Symbol
        String
      end

      private record Token, text : String, line : Int32, kind : Kind

      private class Form
        getter kind, text, children, line

        def initialize(@kind : Kind, @text : String?, @children : Array(Form), @line : Int32)
        end

        def self.list(children : Array(Form), line : Int32) : Form
          new(Kind::List, nil, children, line)
        end

        def self.atom(kind : Kind, text : String, line : Int32) : Form
          new(kind, text, [] of Form, line)
        end

        def list? : Bool
          @kind == Kind::List
        end

        def symbol? : Bool
          @kind == Kind::Symbol
        end

        def string? : Bool
          @kind == Kind::String
        end
      end

      private class Reader
        def initialize(@source : String)
          @tokens = [] of Token
          @line = 1
          @buffer = String::Builder.new
          @token_line = 1
          @in_string = false
          @escaped = false
        end

        def forms : Array(Form)
          @source.each_char { |char| consume(char) }
          flush
          Parser.new(@tokens).forms
        end

        # ameba:disable Metrics/CyclomaticComplexity
        private def consume(char : Char) : Nil
          if @in_string
            @buffer << char
            if char == '"' && !@escaped
              @tokens << Token.new(@buffer.to_s, @token_line, Kind::String)
              @buffer = String::Builder.new
              @in_string = false
            else
              @escaped = char == '\\' && !@escaped
              @escaped = false unless char == '\\'
              @line += 1 if char == '\n'
            end
            return
          end

          case char
          when ';'
            flush
            # Semicolon comments extend to the end of the physical line.
            @skip_comment = true
          when '\n'
            flush unless @skip_comment
            @skip_comment = false
            @line += 1
          when ' ', '\t', '\r'
            flush unless @skip_comment
          when '(', '[', ')', ']'
            return if @skip_comment
            flush
            @tokens << Token.new(char.to_s, @line, Kind::Symbol)
          when '"'
            return if @skip_comment
            flush
            @token_line = @line
            @buffer << char
            @in_string = true
          else
            return if @skip_comment
            @token_line = @line if @buffer.empty?
            @buffer << char
          end
        end

        # ameba:enable Metrics/CyclomaticComplexity

        private def flush : Nil
          return if @buffer.empty?
          @tokens << Token.new(@buffer.to_s, @token_line, Kind::Symbol)
          @buffer = String::Builder.new
        end
      end

      private class Parser
        def initialize(@tokens : Array(Token))
          @index = 0
        end

        def forms : Array(Form)
          result = [] of Form
          while form = read_form
            result << form
          end
          result
        end

        private def read_form : Form?
          return nil if @index >= @tokens.size
          token = @tokens[@index]
          @index += 1
          case token.text
          when "(", "["
            closing = token.text == "(" ? ")" : "]"
            children = [] of Form
            while @index < @tokens.size && @tokens[@index].text != closing
              if child = read_form
                children << child
              end
            end
            @index += 1 if @index < @tokens.size
            Form.list(children, token.line)
          when ")", "]"
            nil
          else
            Form.atom(token.kind, token.text, token.line)
          end
        end
      end

      SCHEME_EXTENSIONS      = {"scm", "ss", "sld", "sls", "sps", "rkt"}
      COMMON_LISP_EXTENSIONS = {"lisp", "lsp", "cl", "asd"}
      SCHEME_DEFINES         = Set{"define", "define*", "define-public", "define/contract", "define/public"}
      SCHEME_MACROS          = Set{"define-syntax", "define-syntax-rule"}
      COMMON_LISP_FUNCTIONS  = Set{"defun", "defmacro", "defgeneric"}
      COMMON_LISP_VARIABLES  = Set{"defvar", "defparameter", "defconstant", "defglobal"}
      COMMON_LISP_CLASSES    = Set{"defclass", "defstruct", "deftype", "define-condition"}
      SPECIAL_FORMS          = Set{
        "define", "define*", "define-public", "define/contract", "define/public", "define-values", "define-syntax", "define-syntax-rule",
        "defun", "defmacro", "defgeneric", "defmethod", "defvar", "defparameter", "defconstant", "defglobal", "defclass", "defstruct", "deftype", "define-condition",
        "lambda", "let", "let*", "letrec", "let-values", "letrec-values", "if", "when", "unless", "cond", "case", "begin", "and", "or", "not", "quote", "quasiquote",
        "set!", "setf", "progn", "loop", "dolist", "dotimes", "labels", "flet", "macrolet", "funcall", "apply", "declare", "in-package", "defpackage", "define-package", "export", "provide", "import", "require", "use-modules", "load", "define-library", "define-module",
      }

      def extract(file : SourceFile) : CodeGraph
        language = language_for(file.path)
        forms = Reader.new(file.content).forms
        namespace = language == "commonlisp" ? package_for(forms) : nil
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        forms_to_scan(forms).each { |form| collect_imports(form, file.path, imports) }
        forms_to_scan(forms).each { |form| collect_definitions(form, file.path, language, namespace, defines) }

        explicit_exports = explicit_exports_for(forms, language)
        callable = defines.select { |definition| definition.kind == SymbolKind::Function }.map(&.name).to_set
        if explicit_exports
          explicit_exports.each do |bare|
            name = qualify(bare, namespace)
            exports << ExportsFact.new(file: file.path, name: name) if defines.any? { |definition| definition.name == name }
          end
        else
          defines.each do |definition|
            exports << ExportsFact.new(file: file.path, name: definition.name) if definition.kind == SymbolKind::Function
          end
        end

        call_set = Set(String).new
        forms_to_scan(forms).each do |form|
          collect_calls_for_definition(form, language, namespace, callable, calls, call_set, file.path)
        end

        CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports.uniq { |entry| {entry.name, entry.source} },
          exports: exports.uniq(&.name),
          files: [FileNode.new(path: file.path, language: language, line_count: line_count(file.content), token_estimate: (file.content.size / 3.5).ceil.to_i32, file_doc: file_doc(file.content), namespace: namespace)],
        )
      end

      def extract_all(files : Array(SourceFile)) : CodeGraph
        graphs = files.map { |file| extract(file) }
        merged = CodeGraph.new(
          defines: graphs.flat_map(&.defines), calls: graphs.flat_map(&.calls), imports: graphs.flat_map(&.imports), exports: graphs.flat_map(&.exports),
          files: graphs.compact_map(&.files).flatten,
        )
        resolve_common_lisp_package_calls(merged)
      end

      def language_for(path : String) : String
        ext = File.extname(path).lstrip('.').downcase
        return "racket" if ext == "rkt"
        return "scheme" if SCHEME_EXTENSIONS.includes?(ext)
        return "commonlisp" if COMMON_LISP_EXTENSIONS.includes?(ext)
        "scheme"
      end

      private def forms_to_scan(forms : Array(Form)) : Array(Form)
        result = [] of Form
        forms.each do |form|
          if head(form).in?("begin", "progn")
            result.concat(forms_to_scan(form.children[1..]))
          elsif head(form) == "define-library"
            form.children.each do |child|
              result.concat(forms_to_scan(child.children[1..])) if child.list? && head(child) == "begin"
            end
          else
            result << form
          end
        end
        result
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def collect_definitions(form : Form, file : String, language : String, namespace : String?, defines : Array(DefinesFact)) : Nil
        return unless form.list?
        name = head(form)
        return unless name
        args = form.children[1..]
        if language == "commonlisp"
          if COMMON_LISP_FUNCTIONS.includes?(name)
            add_definition(defines, file, plain_name(args.first?), SymbolKind::Function, form.line, signature_from(args[1]?), namespace)
          elsif COMMON_LISP_VARIABLES.includes?(name)
            add_definition(defines, file, plain_name(args.first?), SymbolKind::Variable, form.line, nil, namespace)
          elsif COMMON_LISP_CLASSES.includes?(name)
            subject = args.first?
            class_name = plain_name(subject)
            class_name ||= plain_name(subject.children.first?) if subject && subject.list?
            add_definition(defines, file, class_name, SymbolKind::Class, form.line, nil, namespace)
          end
          return
        end

        if SCHEME_DEFINES.includes?(name)
          target = args.first?
          if target && target.list?
            add_definition(defines, file, plain_name(target.children.first?), SymbolKind::Function, form.line, signature_from(target.children[1..]))
          else
            value = args[1]?
            kind = value.try { |entry| head(entry) == "lambda" } ? SymbolKind::Function : SymbolKind::Variable
            signature = value.try { |entry| signature_from(entry.children[1]?) } if kind == SymbolKind::Function
            add_definition(defines, file, plain_name(target), kind, form.line, signature)
          end
        elsif name == "define-values"
          args.first?.try(&.children).try &.each { |binding| add_definition(defines, file, plain_name(binding), SymbolKind::Variable, form.line, nil) }
        elsif SCHEME_MACROS.includes?(name)
          target = args.first?
          macro_name = target && target.list? ? plain_name(target.children.first?) : plain_name(target)
          add_definition(defines, file, macro_name, SymbolKind::Function, form.line, nil)
        elsif name.in?("struct", "define-struct", "define-record-type")
          add_definition(defines, file, plain_name(args.first?), SymbolKind::Class, form.line, nil)
        end
      end

      # ameba:enable Metrics/CyclomaticComplexity

      private def add_definition(defines : Array(DefinesFact), file : String, name : String?, kind : SymbolKind, line : Int32, signature : String?, namespace : String? = nil) : Nil
        return unless name
        qualified = qualify(name, namespace)
        return if defines.any? { |definition| definition.name == qualified }
        defines << DefinesFact.new(file: file, name: qualified, kind: kind, span: Span.line_range(line), signature: signature)
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def collect_imports(form : Form, file : String, imports : Array(ImportsFact)) : Nil
        return unless form.list?
        case head(form)
        when "import", "use-modules"
          form.children[1..].each { |entry| add_import(file, entry, imports) }
        when "require"
          form.children[1..].each { |entry| add_import(file, entry, imports, slash: true) }
        when "load"
          if source = string_value(form.children[1]?)
            imports << ImportsFact.new(file: file, name: source, source: source)
          end
        when "define-module"
          form.children.each do |entry|
            next unless entry.symbol? && entry.text.try(&.starts_with?("#:use-module"))
          end
          form.children.each { |entry| collect_imports(entry, file, imports) if entry.list? }
        when "defpackage", "define-package"
          form.children[2..].each do |option|
            next unless option.list?
            next unless designator(option.children.first?).in?("use", "import-from", "use-reexport")
            option.children[1..].each do |entry|
              if name = designator(entry)
                imports << ImportsFact.new(file: file, name: name, source: name)
              end
            end
          end
        end
        form.children.each { |child| collect_imports(child, file, imports) if child.list? && head(form) == "define-library" }
      end

      # ameba:enable Metrics/CyclomaticComplexity

      private def add_import(file : String, form : Form, imports : Array(ImportsFact), slash : Bool = false) : Nil
        candidate = import_name(form, slash)
        return unless candidate
        imports << ImportsFact.new(file: file, name: candidate, source: candidate)
      end

      private def import_name(form : Form?, slash : Bool) : String?
        return nil unless form
        return string_value(form) if form.string?
        return nil unless form.list?
        if head(form).in?("only", "except", "prefix", "rename", "only-in", "except-in", "prefix-in", "rename-in")
          return import_name(form.children[1]?, slash)
        end
        pieces = form.children.compact_map { |child| plain_name(child) || string_value(child) }
        return nil if pieces.empty?
        pieces.join(slash ? "/" : ".")
      end

      private def explicit_exports_for(forms : Array(Form), language : String) : Array(String)?
        exports = [] of String
        found = forms.any? { |form| collect_explicit_exports(form, language, exports) }
        found ? exports : nil
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def collect_explicit_exports(form : Form, language : String, exports : Array(String)) : Bool
        if form.list? && head(form).in?("export", "provide")
          form.children[1..].each do |entry|
            if name = plain_name(entry)
              exports << name
            end
          end
          return true
        end
        if form.list? && language == "commonlisp" && head(form).in?("defpackage", "define-package")
          found = false
          form.children[2..].each do |option|
            next unless option.list? && designator(option.children.first?) == "export"
            found = true
            option.children[1..].each do |entry|
              if name = designator(entry)
                exports << name
              end
            end
          end
          return found
        end
        return false unless form.list? && language == "scheme" && head(form) == "define-library"

        form.children.any? { |child| collect_explicit_exports(child, language, exports) }
      end

      # ameba:enable Metrics/CyclomaticComplexity

      # ameba:disable Metrics/CyclomaticComplexity
      private def collect_calls_for_definition(form : Form, language : String, namespace : String?, callable : Set(String), calls : Array(CallsFact), call_set : Set(String), file : String) : Nil
        return unless form.list?
        head_name = head(form)
        args = form.children[1..]
        caller = nil.as(String?)
        body = [] of Form
        if language == "commonlisp" && (COMMON_LISP_FUNCTIONS.includes?(head_name) || head_name == "defmethod")
          caller = qualify(plain_name(args.first?), namespace)
          body = args[2..]
        elsif language != "commonlisp" && SCHEME_DEFINES.includes?(head_name)
          target = args.first?
          caller = plain_name(target)
          caller ||= plain_name(target.children.first?) if target && target.list?
          body = target.try(&.list?) ? args[1..] : args[1..]
        elsif language != "commonlisp" && head_name == "define-values"
          caller = plain_name(args.first?.try(&.children).try(&.first?))
          body = args[1..]
        elsif language == "commonlisp" && COMMON_LISP_VARIABLES.includes?(head_name)
          caller = qualify(plain_name(args.first?), namespace)
          body = args[1..]
        elsif !SPECIAL_FORMS.includes?(head_name)
          caller = "<toplevel:#{file}>"
          body = [form]
        end
        return unless caller
        walk_calls(body, caller, namespace, callable, Set(String).new, calls, call_set)
      end

      # ameba:enable Metrics/CyclomaticComplexity

      private def walk_calls(forms : Array(Form), caller : String, namespace : String?, callable : Set(String), bound : Set(String), calls : Array(CallsFact), call_set : Set(String)) : Nil
        forms.each { |form| walk_call(form, caller, namespace, callable, bound, calls, call_set) }
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def walk_call(form : Form, caller : String, namespace : String?, callable : Set(String), bound : Set(String), calls : Array(CallsFact), call_set : Set(String)) : Nil
        return unless form.list?
        name = head(form)
        return unless name
        if name.in?("let", "let*", "letrec", "labels", "flet")
          nested = bound.dup
          if bindings = form.children[1]?
            bindings.children.each do |entry|
              if entry.list?
                if local = plain_name(entry.children.first?)
                  nested << local
                end
              end
            end
          end
          walk_calls(form.children[1..], caller, namespace, callable, nested, calls, call_set)
          return
        end
        unless SPECIAL_FORMS.includes?(name) || bound.includes?(name)
          callee = resolve_name(name.sub(/^#'/, "").gsub("::", ":"), namespace, callable)
          # Keep unknown heads too: they may be a sibling Common Lisp package
          # definition resolved after the batch has been merged.
          emit(caller, callee, calls, call_set)
        end
        form.children.each do |child|
          if child.symbol?
            reference = plain_name(child)
            next if reference.nil? || bound.includes?(reference)
            callee = resolve_name(reference.sub(/^#'/, "").gsub("::", ":"), namespace, callable)
            emit(caller, callee, calls, call_set) if callable.includes?(callee)
          else
            walk_call(child, caller, namespace, callable, bound, calls, call_set)
          end
        end
      end

      # ameba:enable Metrics/CyclomaticComplexity

      private def emit(caller : String, callee : String, calls : Array(CallsFact), call_set : Set(String)) : Nil
        return if caller == callee
        key = "#{caller}->#{callee}"
        return if call_set.includes?(key)
        call_set << key
        calls << CallsFact.new(caller: caller, callee: callee)
      end

      private def resolve_name(name : String, namespace : String?, callable : Set(String)) : String
        qualified = qualify(name, namespace)
        callable.includes?(qualified) ? qualified : name
      end

      def resolve_common_lisp_package_calls(graph : CodeGraph) : CodeGraph
        package_defs = graph.defines.map(&.name).to_set
        packages_by_file = Hash(String, String).new
        (graph.files || [] of FileNode).each do |file|
          if namespace = file.namespace
            packages_by_file[file.path] = namespace
          end
        end
        calls = graph.calls.map do |call|
          next call if call.callee.includes?(':')
          package = if call.caller.includes?(':')
                      call.caller.split(':', 2).first?
                    elsif match = /^<toplevel:(.*)>$/.match(call.caller)
                      packages_by_file[match[1]]?
                    end
          next call unless package
          qualified = "#{package}:#{call.callee}"
          package_defs.includes?(qualified) ? CallsFact.new(caller: call.caller, callee: qualified, callee_qn: call.callee_qn, caller_qn: call.caller_qn) : call
        end
        CodeGraph.new(
          defines: graph.defines, calls: calls, imports: graph.imports, exports: graph.exports,
          contains: graph.contains, files: graph.files, type_info: graph.type_info,
        )
      end

      private def package_for(forms : Array(Form)) : String?
        forms.each do |form|
          next unless head(form) == "in-package"
          return designator(form.children[1]?)
        end
        nil
      end

      private def designator(form : Form?) : String?
        raw = plain_name(form) || string_value(form)
        raw.try(&.sub(/^#?:/, ""))
      end

      private def qualify(name : String?, namespace : String?) : String
        value = name || ""
        return value if namespace.nil? || value.includes?(':')
        "#{namespace}:#{value}"
      end

      private def head(form : Form?) : String?
        plain_name(form.try(&.children).try(&.first?))
      end

      private def plain_name(form : Form?) : String?
        return nil unless form && form.symbol?
        form.text
      end

      private def string_value(form : Form?) : String?
        return nil unless form && form.string?
        form.text.try { |value| value[1...-1] }
      end

      private def signature_from(forms : Array(Form)) : String?
        "(#{forms.compact_map { |form| plain_name(form) }.join(" ")})"
      end

      private def signature_from(form : Form?) : String?
        return nil unless form
        form.list? ? signature_from(form.children) : nil
      end

      private def line_count(source : String) : Int32
        return 0 if source.empty?
        source.count('\n') + (source.ends_with?('\n') ? 0 : 1)
      end

      private def file_doc(source : String) : String?
        lines = [] of String
        source.each_line do |line|
          stripped = line.lstrip
          break unless stripped.starts_with?(";;;")
          text = stripped.lchop(";").lchop(";").lchop(";").strip
          lines << text unless text.empty?
        end
        return nil if lines.empty?
        lines.join(" ")
      end
    end
  end
end
