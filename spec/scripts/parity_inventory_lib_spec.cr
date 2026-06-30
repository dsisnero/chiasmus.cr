require "../spec_helper"
require "file_utils"

describe "parity_inventory_lib.rb" do
  it "treats the Crystal discovery binary as tree-sitter availability" do
    dir = File.join(Dir.tempdir, "parity-inventory-lib-#{Random::Secure.hex(8)}")
    scripts_dir = File.join(dir, "scripts")
    bin_dir = File.join(dir, "bin")
    Dir.mkdir_p(scripts_dir)
    Dir.mkdir_p(bin_dir)

    begin
      source_lib = File.expand_path("../../scripts/parity_inventory_lib.rb", __DIR__)
      FileUtils.cp(source_lib, File.join(scripts_dir, "parity_inventory_lib.rb"))

      discover_bin = File.join(bin_dir, "chiasmus-discover")
      File.write(discover_bin, <<-SH)
#!/usr/bin/env bash
exit 0
SH
      File.chmod(discover_bin, 0o755_i32)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "ruby",
        [
          "-e",
          "require './scripts/parity_inventory_lib'; puts ParityInventory.effective_parser('typescript', 'tree-sitter')",
        ],
        chdir: dir,
        output: output_io,
        error: error_io
      )

      status.success?.should be_true, error_io.to_s
      output_io.to_s.should eq("tree-sitter\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses discovery-binary output without mutating unknown item fields" do
    dir = File.join(Dir.tempdir, "parity-inventory-lib-#{Random::Secure.hex(8)}")
    scripts_dir = File.join(dir, "scripts")
    bin_dir = File.join(dir, "bin")
    source_dir = File.join(dir, "vendor", "upstream")
    Dir.mkdir_p(scripts_dir)
    Dir.mkdir_p(bin_dir)
    Dir.mkdir_p(source_dir)

    begin
      source_lib = File.expand_path("../../scripts/parity_inventory_lib.rb", __DIR__)
      FileUtils.cp(source_lib, File.join(scripts_dir, "parity_inventory_lib.rb"))

      discover_bin = File.join(bin_dir, "chiasmus-discover")
      File.write(discover_bin, <<-SH)
#!/usr/bin/env bash
printf 'src/app.ts::function::main\tfunction\n'
SH
      File.chmod(discover_bin, 0o755_i32)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "ruby",
        [
          "-e",
          <<-RUBY,
          require './scripts/parity_inventory_lib'
          base, items = ParityInventory.discover_items(root_dir: '.', source_path: 'vendor/upstream', language: 'typescript', parser_mode: 'tree-sitter')
          puts base
          puts items.first.id
          RUBY
        ],
        chdir: dir,
        output: output_io,
        error: error_io
      )

      status.success?.should be_true, error_io.to_s
      output = output_io.to_s
      output.should contain(File.join(dir, "vendor", "upstream"))
      output.should contain("src/app.ts::function::main")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
