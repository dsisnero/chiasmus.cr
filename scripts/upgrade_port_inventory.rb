#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"

HEADER = %w[source_id kind status crystal_refs target_symbol test_refs notes].freeze
TARGET_PATTERNS = [
  /ported as\s+([A-Za-z0-9_:#.?!+=-]+)/i,
  /represented by\s+([A-Za-z0-9_:#.?!+=-]+)/i,
  /replaced by\s+([A-Za-z0-9_:#.?!+=-]+)/i
].freeze
TEST_REF_PATTERN = /
  (?:
    ^|
    [\s,(]
  )
  (
    (?:
      spec|test
    )
    \/[^,\s)]+?\.cr
    (?::\d+)?
  )
/x.freeze

options = {
  input: nil,
  output: nil,
  in_place: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: upgrade_port_inventory.rb --input FILE [--output FILE | --in-place]"
  opts.on("--input FILE", "Legacy or header-driven inventory TSV") { |v| options[:input] = v }
  opts.on("--output FILE", "Write upgraded TSV to FILE") { |v| options[:output] = v }
  opts.on("--in-place", "Rewrite the input file in place") { options[:in_place] = true }
end.parse!

abort "--input is required" unless options[:input]
abort "choose either --output or --in-place" if options[:output] && options[:in_place]

input_path = Pathname(options[:input]).expand_path
abort "missing input: #{input_path}" unless input_path.file?

output_path =
  if options[:in_place]
    input_path
  elsif options[:output]
    Pathname(options[:output]).expand_path
  else
    nil
  end

def normalize_header(line)
  line.sub(/\A#\s*/, "").split("\t", -1).map { |value| value.strip.downcase }
end

def inventory_header?(line)
  cols = normalize_header(line)
  cols.include?("source_id") && cols.include?("kind") && cols.include?("status")
end

def empty_to_dash(value)
  stripped = value.to_s.strip
  stripped.empty? ? "-" : stripped
end

def row_from_header(cols, header)
  {
    "source_id"     => cols[header.fetch("source_id")] || "",
    "kind"          => cols[header.fetch("kind")] || "",
    "status"        => cols[header.fetch("status")] || "",
    "crystal_refs"  => empty_to_dash(header["crystal_refs"] && cols[header["crystal_refs"]]),
    "target_symbol" => empty_to_dash(header["target_symbol"] && cols[header["target_symbol"]]),
    "test_refs"     => empty_to_dash(header["test_refs"] && cols[header["test_refs"]]),
    "notes"         => empty_to_dash(header["notes"] && cols[header["notes"]])
  }
end

def row_from_legacy(cols)
  raise "expected at least 5 columns, got #{cols.length}" if cols.length < 5

  {
    "source_id"     => cols[0],
    "kind"          => cols[1],
    "status"        => cols[2],
    "crystal_refs"  => empty_to_dash(cols[3]),
    "target_symbol" => "-",
    "test_refs"     => "-",
    "notes"         => empty_to_dash(cols[4])
  }
end

def extract_target_symbol(notes)
  return "-" if notes == "-"

  TARGET_PATTERNS.each do |pattern|
    match = notes.match(pattern)
    next unless match

    candidate = match[1].sub(/[.,;]\z/, "")
    next unless symbol_like?(candidate)

    return candidate unless candidate.empty?
  end

  "-"
end

def symbol_like?(candidate)
  return false if candidate.nil? || candidate.empty?

  candidate.include?("::") ||
    candidate.include?(".") ||
    candidate.include?("#") ||
    candidate.include?("_") ||
    candidate.end_with?("?", "!") ||
    candidate.match?(/\A[A-Z][A-Za-z0-9]*\z/)
end

def extract_test_refs(crystal_refs, notes)
  refs = []

  [crystal_refs, notes].each do |source|
    next if source.nil? || source == "-"

    source.scan(TEST_REF_PATTERN) do |match|
      refs << match[0]
    end
  end

  refs.uniq!
  refs.empty? ? "-" : refs.join(",")
end

rows = []
header = nil

File.readlines(input_path, chomp: true).each do |line|
  next if line.strip.empty?

  if header.nil? && inventory_header?(line)
    header = normalize_header(line).each_with_index.to_h
    next
  end

  next if line.start_with?("#")

  cols = line.split("\t", -1)
  row = header ? row_from_header(cols, header) : row_from_legacy(cols)
  row["target_symbol"] = extract_target_symbol(row["notes"]) if row["target_symbol"] == "-"
  row["test_refs"] = extract_test_refs(row["crystal_refs"], row["notes"]) if row["test_refs"] == "-"
  rows << row
end

output = String.new
output << "# #{HEADER.join("\t")}\n"
rows.each do |row|
  output << HEADER.map { |name| empty_to_dash(row[name]) }.join("\t")
  output << "\n"
end

if output_path
  output_path.dirname.mkpath
  output_path.write(output)
else
  print output
end
