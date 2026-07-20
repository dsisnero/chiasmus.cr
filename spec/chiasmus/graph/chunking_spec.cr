require "../../spec_helper"

describe Chiasmus::Graph::Chunking do
  next pending("crystal grammar not available") unless Chiasmus::Graph::Parser.get_language("crystal")

  it "chunks top-level definitions without merging unrelated methods when each fits" do
    source = <<-CR
      def alpha
        1
      end

      def beta
        2
      end
    CR

    chunks = Chiasmus::Graph::Chunking.chunk_source(
      source,
      "sample.cr",
      max_chunk_size: 28
    )

    chunks.size.should eq(2)
    chunks.map(&.content).join.should eq(source)
    chunks[0].content.should contain("def alpha")
    chunks[0].content.should_not contain("def beta")
    chunks[0].context.symbols_defined.should eq(["alpha"])
    chunks[1].content.should contain("def beta")
    chunks[1].context.symbols_defined.should eq(["beta"])
  end

  it "carries enclosing context and comments when splitting an oversized class into method chunks" do
    source = <<-CR
      class Greeter
        # says hi
        def greet(name)
          puts name
        end

        def part(name)
          puts name
        end
      end
    CR

    chunks = Chiasmus::Graph::Chunking.chunk_source(
      source,
      "greeter.cr",
      max_chunk_size: 48
    )

    greet_chunk = chunks.find { |chunk| chunk.content.includes?("def greet") }
    greet_chunk.should_not be_nil

    greet = greet_chunk.not_nil!
    greet.context.context_path.should eq(["Greeter"])
    greet.context.symbols_defined.should eq(["greet"])
    greet.context.comments.map(&.text).should contain("says hi")
  end

  it "falls back to contiguous raw splitting when a single definition exceeds max_chunk_size" do
    source = <<-CR
      def huge
        puts "one"
        puts "two"
        puts "three"
        puts "four"
        puts "five"
      end
    CR

    chunks = Chiasmus::Graph::Chunking.chunk_source(
      source,
      "huge.cr",
      max_chunk_size: 24
    )

    chunks.size.should be > 1
    chunks.map(&.content).join.should eq(source)

    chunks.each_cons_pair do |left, right|
      left.span.end_byte.should eq(right.span.start_byte)
    end
  end
end
