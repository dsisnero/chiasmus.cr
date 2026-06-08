require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/map"
require "file_utils"

include Chiasmus::Graph

describe Chiasmus::Graph::Extractor do
  describe "#extract_graph" do
    it "populates CodeGraph.files with FileNode per processed source file" do
      tmpdir = Dir.tempdir
      go_file = File.join(tmpdir, "test_extract.go")
      crystal_file = File.join(tmpdir, "test_extract.cr")

      begin
        File.write(go_file, <<-GO)
          package main

          func main() {
            helper()
          }

          func helper() {}
        GO

        File.write(crystal_file, <<-CR)
          def main
            helper
          end

          def helper
          end
        CR

        sources = [
          SourceFile.new(path: go_file, content: File.read(go_file)),
          SourceFile.new(path: crystal_file, content: File.read(crystal_file)),
        ]

        graph = Extractor.extract_graph(sources)

        graph.files.should_not be_nil
        file_nodes = graph.files || raise "Expected files to be non-nil"
        file_nodes.size.should be >= 1
        file_nodes.find(&.path.==(go_file)).should_not be_nil
      ensure
        File.delete(go_file) if File.exists?(go_file)
        File.delete(crystal_file) if File.exists?(crystal_file)
      end
    end

    it "FileNode includes path, language, line_count, and token_estimate" do
      tmpdir = Dir.tempdir
      go_file = File.join(tmpdir, "test_filenode.go")

      begin
        File.write(go_file, <<-GO)
          package main

          func main() {
            helper()
          }

          func helper() {}
        GO

        sources = [
          SourceFile.new(path: go_file, content: File.read(go_file)),
        ]

        graph = Extractor.extract_graph(sources)

        file_nodes = graph.files || raise "Expected files to be non-nil"
        fn = file_nodes.find! { |file_node| file_node.path == go_file }
        fn.language.should eq("go")
        fn.line_count.should_not be_nil
        lc = fn.line_count || raise "Expected line_count to be non-nil"
        lc.should be > 0
        fn.token_estimate.should_not be_nil
        te = fn.token_estimate || raise "Expected token_estimate to be non-nil"
        te.should be > 0
      ensure
        File.delete(go_file) if File.exists?(go_file)
      end
    end

    it "map overview shows Files > 0 after extract_graph fix" do
      tmpdir = Dir.tempdir
      go_file = File.join(tmpdir, "map_overview_test.go")

      begin
        File.write(go_file, <<-GO)
          package main

          func main() {
            helper()
          }

          func helper() {}
        GO

        sources = [
          SourceFile.new(path: go_file, content: File.read(go_file)),
        ]

        graph = Extractor.extract_graph(sources)
        map = CodebaseMap.build_overview(graph)

        map.should_not be_nil
        m = map || raise "Expected map to be non-nil"
        m.summary.files.should eq(1)
      ensure
        File.delete(go_file) if File.exists?(go_file)
      end
    end
  end
end
