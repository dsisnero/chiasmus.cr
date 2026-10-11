require "spec"
require "file_utils"
require "../../spec_helper"

describe "chiasmus-parity --format maps-prolog" do
  it "emits a self-contained Prolog program with query rules" do
    dir = File.join(Dir.tempdir, "chiasmus-maps-prolog-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    source_facts = File.join(dir, "source.pl")
    File.write(source_facts, <<-PL)
    defines('a/COSBase.java', 'COSBase', class, 1, 2).
    defines('a/COSStream.java', 'COSStream', class, 1, 2).
    PL

    crystal_facts = File.join(dir, "crystal.pl")
    File.write(crystal_facts, <<-PL)
    defines('src/cos.cr', 'Base', class, 1, 2).
    defines('src/cos.cr', 'Stream', class, 3, 4).
    contains('Pdfbox::Cos', 'Base').
    contains('Pdfbox::Cos', 'Stream').
    PL

    rules = File.join(dir, "rules.yml")
    File.write(rules, <<-YAML)
    version: 1
    source_language: java
    target_language: crystal
    match_owner: true
    source:
      strip_prefix: [COS]
    target:
      strip_prefix: [COS]
    YAML

    output = IO::Memory.new
    error = IO::Memory.new
    exit_code = Chiasmus::Parity::CLI.run(
      ["--source-facts", source_facts, "--crystal-facts", crystal_facts, "--map-rules", rules, "--format", "maps-prolog"],
      output,
      error,
    )

    exit_code.should eq(0)
    text = output.to_s
    text.should contain("entity(")
    text.should contain("maps_to(")
    text.should contain("source_entity(")
    text.should contain("falsely_missing(Id) :-")
    text.should contain("inventory_entity(")
    text.should contain("surface_status(")
    text.should contain("surface_ok(Id) :-")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "requires source and crystal facts" do
    output = IO::Memory.new
    error = IO::Memory.new
    exit_code = Chiasmus::Parity::CLI.run(["--format", "maps-prolog"], output, error)
    exit_code.should eq(1)
    error.to_s.should contain("--source-facts and --crystal-facts are required")
  end
end
