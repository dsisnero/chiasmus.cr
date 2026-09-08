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
end
