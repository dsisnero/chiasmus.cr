#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'fileutils'

options = {
  old: nil,
  new: nil,
  out: nil
}

OptionParser.new do |opts|
  opts.banner = 'Usage: compare_upstream_fingerprints.rb --old OLD.tsv --new NEW.tsv [--out report.tsv]'
  opts.on('--old FILE', 'Previous fingerprint TSV') { |v| options[:old] = v }
  opts.on('--new FILE', 'New fingerprint TSV') { |v| options[:new] = v }
  opts.on('--out FILE', 'Output report path (default: stdout)') { |v| options[:out] = v }
end.parse!

abort '--old is required' unless options[:old]
abort '--new is required' unless options[:new]

def load_rows(path)
  rows = {}
  File.readlines(path, chomp: true).each do |line|
    next if line.strip.empty? || line.start_with?('#')

    cols = line.split("\t", -1)
    raise "Malformed fingerprint row in #{path}: #{line}" if cols.size < 11

    id = cols[0]
    rows[id] = {
      id: id,
      kind: cols[1],
      scope: cols[2],
      file: cols[3],
      name: cols[4],
      feature: cols[5],
      file_sha: cols[6],
      item_sha: cols[7],
      start_line: cols[8],
      end_line: cols[9],
      extraction: cols[10],
    }
  end
  rows
end

old_rows = load_rows(options[:old])
new_rows = load_rows(options[:new])

report = []

(new_rows.keys - old_rows.keys).sort.each do |id|
  row = new_rows.fetch(id)
  report << ['added', id, row[:kind], row[:scope], row[:feature], '-', row[:item_sha], '-', row[:file_sha], 'new upstream item']
end

(old_rows.keys - new_rows.keys).sort.each do |id|
  row = old_rows.fetch(id)
  report << ['removed', id, row[:kind], row[:scope], row[:feature], row[:item_sha], '-', row[:file_sha], '-', 'upstream item removed or renamed']
end

(old_rows.keys & new_rows.keys).sort.each do |id|
  old_row = old_rows.fetch(id)
  new_row = new_rows.fetch(id)
  next if old_row[:item_sha] == new_row[:item_sha] && old_row[:file_sha] == new_row[:file_sha]

  change_type = old_row[:item_sha] == new_row[:item_sha] ? 'context_changed' : 'changed'
  note = change_type == 'changed' ? 'item fingerprint changed' : 'file changed outside extracted item block'
  report << [
    change_type,
    id,
    new_row[:kind],
    new_row[:scope],
    new_row[:feature],
    old_row[:item_sha],
    new_row[:item_sha],
    old_row[:file_sha],
    new_row[:file_sha],
    note,
  ]
end

output = +"# change_type\tsource_id\tkind\tscope\tfeature\told_item_sha256\tnew_item_sha256\told_file_sha256\tnew_file_sha256\tnotes\n"
report.each do |row|
  output << row.join("\t") << "\n"
end

if options[:out]
  FileUtils.mkdir_p(File.dirname(options[:out]))
  File.write(options[:out], output)
else
  print output
end
