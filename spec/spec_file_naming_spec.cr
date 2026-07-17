require "./spec_helper"

def scan_spec_tree(dir : String, acc : Array(String)) : Nil
  Dir.each_child(dir) do |entry|
    path = File.join(dir, entry)
    acc << path
    scan_spec_tree(path, acc) if File.directory?(path)
  end
end

describe "spec file naming" do
  it "does not contain AppleDouble files under spec/" do
    paths = [] of String
    scan_spec_tree("spec", paths)

    offenders = paths.select do |path|
      File.basename(path).starts_with?("._")
    end

    offenders.should eq([] of String)
  end

  it "keeps executable spec files on *_spec.cr or *_spec.rb names" do
    paths = [] of String
    scan_spec_tree("spec", paths)

    offenders = paths.select do |path|
      next false unless File.file?(path)
      next false if path == "spec/spec_helper.cr"
      next false if path.starts_with?("spec/support/")
      next false if path.starts_with?("spec/testdata/")
      next false if File.extname(path).empty?

      ext = File.extname(path)
      next false unless {".cr", ".rb"}.includes?(ext)

      !path.matches?(/_spec\.(cr|rb)\z/)
    end

    offenders.should eq([] of String)
  end
end
