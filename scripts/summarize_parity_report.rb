#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

options = { input: nil }

OptionParser.new do |opts|
  opts.banner = "Usage: summarize_parity_report.rb --input FILE"
  opts.on("--input FILE", "TSV output from chiasmus-parity") { |v| options[:input] = v }
end.parse!

abort "--input is required" unless options[:input]
abort "missing input: #{options[:input]}" unless File.file?(options[:input])

rows = []
File.readlines(options[:input], chomp: true).each do |line|
  next if line.strip.empty? || line.start_with?("#")

  cols = line.split("\t", -1)
  next if cols.length < 12

  rows << {
    source_id: cols[0],
    match_status: cols[3],
    structural_status: cols[9],
    structural_details: cols[10]
  }
end

match_counts = Hash.new(0)
structural_counts = Hash.new(0)
drift_match_counts = Hash.new(0)
detail_counts = Hash.new(0)

rows.each do |row|
  match_counts[row[:match_status]] += 1
  structural_counts[row[:structural_status]] += 1

  next unless row[:structural_status] == "structural_drift"

  drift_match_counts[row[:match_status]] += 1
  next if row[:structural_details] == "-" || row[:structural_details].empty?

  row[:structural_details].split(/\s*;\s*/).each do |detail|
    next if detail.empty?

    detail_counts[detail] += 1
  end
end

puts "# Match Status Counts"
match_counts.sort_by { |status, count| [-count, status] }.each do |status, count|
  puts "#{count}\t#{status}"
end

puts
puts "# Structural Status Counts"
structural_counts.sort_by { |status, count| [-count, status] }.each do |status, count|
  puts "#{count}\t#{status}"
end

puts
puts "# Structural Drift by Match Status"
drift_match_counts.sort_by { |status, count| [-count, status] }.each do |status, count|
  puts "#{count}\t#{status}"
end

puts
puts "# Top Structural Drift Details"
detail_counts.sort_by { |detail, count| [-count, detail] }.first(25).each do |detail, count|
  puts "#{count}\t#{detail}"
end
