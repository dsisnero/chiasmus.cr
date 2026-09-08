require "spec"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/parser_language_resolver"
require "../../../src/chiasmus/graph/map"

private def extract_sexp_graph(content : String, path : String) : Chiasmus::Graph::CodeGraph
  Chiasmus::Graph::SexpSourceExtractor.extract(Chiasmus::Graph::SourceFile.new(path: path, content: content))
end

describe "S-expression graph extraction" do
  it "maps Scheme, Racket, and Common Lisp extensions to their logical languages" do
    resolver = Chiasmus::Graph::Parser::LanguageResolver.new
    resolver.language_for_file("core.scm").should eq("scheme")
    resolver.language_for_file("library.sld").should eq("scheme")
    resolver.language_for_file("main.rkt").should eq("racket")
    resolver.language_for_file("app.lisp").should eq("commonlisp")
    resolver.language_for_file("system.asd").should eq("commonlisp")
  end

  it "extracts Scheme definitions, imports, explicit exports, and call edges" do
    graph = extract_sexp_graph <<-SCHEME, "core.scm"
      (import (scheme base) (only (srfi 1) fold))
      (export run)
      (define (helper x) x)
      (define (run x) (helper x))
      SCHEME

    graph.defines.map(&.name).should eq(["helper", "run"])
    graph.imports.map(&.name).should eq(["scheme.base", "srfi.1"])
    graph.exports.map(&.name).should eq(["run"])
    graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should eq(["run->helper"])
  end

  it "extracts Common Lisp package-qualified definitions and cross-file calls" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new(path: "a.lisp", content: "(in-package #:app)\n(defun start () (bootstrap))"),
      Chiasmus::Graph::SourceFile.new(path: "b.lisp", content: "(in-package #:app)\n(defun bootstrap () 1)"),
    ])

    graph.defines.map(&.name).should eq(["app:start", "app:bootstrap"])
    graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should eq(["app:start->app:bootstrap"])
  end

  it "records a leading triple-semicolon file document but not a double-semicolon comment" do
    documented = extract_sexp_graph(";;; Request routing helpers.\n;;; Shared by the CLI.\n(define (go) 1)", "core.scm")
    documented.files.not_nil!.first.file_doc.should eq("Request routing helpers. Shared by the CLI.")

    undocumented = extract_sexp_graph(";; Copyright\n(define (go) 1)", "core.scm")
    undocumented.files.not_nil!.first.file_doc.should be_nil
  end

  it "resolves an unqualified map target against package-qualified symbols" do
    graph = extract_sexp_graph("(in-package #:app)\n(defun caller () (callee))\n(defun callee () 1)", "app.lisp")

    detail = Chiasmus::Graph::CodebaseMap.build_symbol_detail(graph, "callee")
    detail.not_nil!.defines.map { |definition| definition[:file] }.should eq(["app.lisp"])
    detail.not_nil!.callers.should eq(["app:caller"])
  end

  it "extracts Racket definitions through the public graph extractor" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new(path: "main.rkt", content: "#lang racket/base\n(provide run)\n(define (run x) x)\n(define helper (lambda (x) x))"),
    ])

    graph.files.not_nil!.first.language.should eq("racket")
    graph.defines.map(&.name).should eq(["run", "helper"])
    graph.exports.map(&.name).should eq(["run"])
  end

  it "honors Common Lisp defpackage imports and exports" do
    graph = extract_sexp_graph <<-LISP, "app.lisp"
      (defpackage #:app (:use #:cl #:alexandria) (:export #:run))
      (in-package #:app)
      (defun run () 1)
      (defun internal () 2)
      LISP

    graph.imports.map(&.name).should eq(["cl", "alexandria"])
    graph.exports.map(&.name).should eq(["app:run"])
  end

  it "extracts Scheme record constructors and accessors" do
    graph = extract_sexp_graph <<-SCHEME, "point.scm"
      (define-record-type point
        (make-point x y)
        point?
        (x point-x set-point-x!)
        (y point-y))
      SCHEME

    graph.defines.select { |definition| definition.kind == Chiasmus::Graph::SymbolKind::Class }.map(&.name).should eq(["point"])
    graph.defines.select { |definition| definition.kind == Chiasmus::Graph::SymbolKind::Function }.map(&.name).should eq(["make-point", "point?", "point-x", "set-point-x!", "point-y"])
  end

  it "extracts Guile module imports and explicit exports" do
    graph = extract_sexp_graph <<-SCHEME, "module.scm"
      (define-module (my mod)
        #:use-module (ice-9 match)
        #:export (go))
      (define (go) 1)
      (define (internal) 2)
      SCHEME

    graph.imports.map(&.name).should eq(["ice-9.match"])
    graph.exports.map(&.name).should eq(["go"])
  end

  it "extracts imports, exports, and definitions nested in an R7RS library" do
    graph = extract_sexp_graph <<-SCHEME, "library.sld"
      (define-library (my lib)
        (export go)
        (import (scheme base))
        (begin
          (define (go) 1)))
      SCHEME

    graph.imports.map(&.name).should eq(["scheme.base"])
    graph.exports.map(&.name).should eq(["go"])
    graph.defines.map(&.name).should eq(["go"])
  end

  it "does not emit calls to Scheme lambda parameters or internal definitions" do
    graph = extract_sexp_graph <<-SCHEME, "scope.scm"
      (define (helper x) x)
      (define (outer proc x)
        (define (inner y) (helper y))
        (proc x)
        (inner x))
      SCHEME

    graph.calls.map(&.callee).should eq(["helper"])
  end

  it "attributes Common Lisp defmethod calls to its generic function and ignores lexical locals" do
    graph = extract_sexp_graph <<-LISP, "methods.lisp"
      (defgeneric area (shape))
      (defmethod area ((shape point))
        (let ((helper 1))
          (compute-area shape)))
      (defun compute-area (shape) shape)
      LISP

    graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should eq(["area->compute-area"])
  end

  it "filters Common Lisp iteration forms and their bound variables from call edges" do
    graph = extract_sexp_graph <<-LISP, "iteration.lisp"
      (defun f (pairs)
        (dolist (pair pairs)
          (multiple-value-bind (quotient remainder) (floor 7 2)
            (list pair quotient remainder))))
      LISP

    callees = graph.calls.map(&.callee)
    callees.should_not contain("dolist")
    callees.should_not contain("multiple-value-bind")
    callees.should_not contain("pair")
    callees.should_not contain("quotient")
    callees.should_not contain("remainder")
    callees.should_not contain("pairs")
  end

  it "extracts bare Racket require paths and unwrapped require specs" do
    graph = extract_sexp_graph <<-RACKET, "main.rkt"
      #lang racket
      (require racket/list "helper.rkt" (only-in racket/string string-join))
      RACKET

    graph.imports.map(&.name).should eq(["racket/list", "helper.rkt", "racket/string"])
  end

  it "does not emit lexical local-function parameters as Common Lisp calls" do
    graph = extract_sexp_graph <<-LISP, "locals.lisp"
      (defun a () 1)
      (defun helper () 1)
      (defun f (x)
        (labels ((h (a) (helper) (a)))
          (h x)))
      LISP

    callees = graph.calls.map(&.callee)
    graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("f->helper")
    callees.should_not contain("h")
    callees.should_not contain("a")
    callees.should_not contain("x")
  end
end
