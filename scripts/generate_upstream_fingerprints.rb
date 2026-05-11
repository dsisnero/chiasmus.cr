#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'optparse'
require_relative 'parity_inventory_lib'

options = {
  root_dir: Dir.pwd,
  source_path: ENV['PORT_SOURCE_DIR'],
  language: ENV['PORT_LANGUAGE'] || 'go',
  parser: ENV['PORT_PARSER'] || 'auto',
  out: nil
}

OptionParser.new do |opts|
  opts.banner = 'Usage: generate_upstream_fingerprints.rb [options]'
  opts.on('--root DIR', 'Project root (default: pwd)') { |v| options[:root_dir] = v }
  opts.on('--source PATH', 'Source path (absolute or relative to root)') { |v| options[:source_path] = v }
  opts.on('--language LANG', 'Language: go|rust|crystal|java|ruby|typescript') { |v| options[:language] = v }
  opts.on('--parser MODE', 'Parser: auto|regex|tree-sitter') { |v| options[:parser] = v }
  opts.on('--out FILE', 'Output TSV path (default: stdout)') { |v| options[:out] = v }
end.parse!

base, items = ParityInventory.discover_items(
  root_dir: options[:root_dir],
  source_path: options[:source_path],
  language: options[:language],
  parser_mode: options[:parser]
)

def sha256(text)
  Digest::SHA256.hexdigest(text.to_s)
end

def feature_area(rel)
  case rel
  when %r{\Abenchmark/} then 'benchmark'
  when %r{\Atests/graph/}, %r{\Asrc/graph/} then 'graph'
  when %r{\Atests/mcp-server\.}, %r{\Asrc/mcp-server\.} then 'mcp'
  when %r{\Atests/.+solver}, %r{\Asrc/solvers/}, %r{\Asrc/tau-prolog} then 'solvers'
  when %r{\Atests/skill}, %r{\Atests/learning}, %r{\Atests/craft}, %r{\Asrc/skills/} then 'skills'
  when %r{\Atests/formalize}, %r{\Asrc/formalize/} then 'formalize'
  when %r{\Atests/config}, %r{\Asrc/config} then 'config'
  when %r{\Asrc/llm/} then 'llm'
  else 'misc'
  end
end

def line_for_item(lines, item)
  name = item.name.to_s
  simple_name = name.split('.').last

  patterns = case item.kind
             when 'class'
               [/class\s+#{Regexp.escape(simple_name)}\b/]
             when 'interface'
               [/interface\s+#{Regexp.escape(simple_name)}\b/]
             when 'type'
               [/type\s+#{Regexp.escape(simple_name)}\s*=/]
             when 'const'
               [/(const|let|var)\s+#{Regexp.escape(simple_name)}\b/, /\b#{Regexp.escape(simple_name)}\s*=/]
             when 'function', 'func'
               [/function\s+#{Regexp.escape(simple_name)}\b/, /\b#{Regexp.escape(simple_name)}\s*=\s*(async\s*)?(\(|[A-Za-z_$])/]
             when 'method'
               [/\b#{Regexp.escape(simple_name)}\s*\(/]
             when 'test'
               [/["']#{Regexp.escape(name)}["']/]
             else
               [/\b#{Regexp.escape(simple_name)}\b/]
             end

  lines.index do |line|
    patterns.any? { |pattern| line.match?(pattern) }
  end
end

def extract_block(lines, start_index)
  return ['', 0, 0, 'file'] unless start_index

  depth = 0
  seen_brace = false
  finish = start_index

  lines[start_index..].each_with_index do |line, offset|
    line.each_char do |char|
      if char == '{'
        depth += 1
        seen_brace = true
      elsif char == '}'
        depth -= 1 if depth > 0
      end
    end

    finish = start_index + offset
    break if seen_brace && depth.zero?
    break if !seen_brace && offset.positive? && line.strip.empty?
  end

  [lines[start_index..finish].join, start_index + 1, finish + 1, seen_brace ? 'block' : 'line']
end

rows = items.map do |item|
  full_path = base + item.file
  content = File.read(full_path)
  lines = content.lines
  start_index = line_for_item(lines, item)
  snippet, start_line, end_line, extraction = extract_block(lines, start_index)
  snippet = content if snippet.empty?

  [
    item.id,
    item.kind,
    item.scope,
    item.file,
    item.name,
    feature_area(item.file),
    sha256(content),
    sha256(snippet),
    start_line,
    end_line,
    extraction,
  ]
end

output = +"# source_id\tkind\tscope\tfile\tname\tfeature\tfile_sha256\titem_sha256\tstart_line\tend_line\textraction\n"
rows.sort_by(&:first).each do |row|
  output << row.join("\t") << "\n"
end

if options[:out]
  FileUtils.mkdir_p(File.dirname(options[:out]))
  File.write(options[:out], output)
else
  print output
end
