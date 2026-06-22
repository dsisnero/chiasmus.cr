require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/discovery/grammar_loader"

include Chiasmus::Graph

describe "Perl graph walker" do
  if Chiasmus::Discovery::GrammarLoader.tree_sitter_available?("perl")
    it "extracts function definitions" do
      code = <<-PL
        sub hello {
          print "world\n";
        }
      PL
      sources = [SourceFile.new(path: "/tmp/t.pl", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.defines.map(&.name).should contain("hello")
    end

    it "captures method calls" do
      code = <<-PL
        sub caller_func {
          my $obj = SomeClass->new();
          $obj->do_thing();
        }
      PL
      sources = [SourceFile.new(path: "/tmp/t.pl", content: code)]
      graph = Extractor.extract_graph(sources)
      callees = graph.calls.map(&.callee).to_set
      callees.size.should be >= 1
    end

    it "captures use statements as imports" do
      code = <<-PL
        use strict;
        use warnings;
        use DBI;
        print "hello\n";
      PL
      sources = [SourceFile.new(path: "/tmp/t.pl", content: code)]
      graph = Extractor.extract_graph(sources)
      import_names = graph.imports.map(&.name).to_set
      import_names.should contain("DBI")
    end

    it "produces file nodes for Perl files" do
      code = "#!/usr/bin/perl\nprint 'hello';\n"
      sources = [SourceFile.new(path: "/tmp/t.pl", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.files.should_not be_nil
      (graph.files || raise("nil")).first.language.should eq("perl")
    end
  else
    pending "extracts function definitions (perl grammar not available)"
    pending "captures method calls (perl grammar not available)"
    pending "captures use statements as imports (perl grammar not available)"
    pending "produces file nodes for Perl files (perl grammar not available)"
  end
end
