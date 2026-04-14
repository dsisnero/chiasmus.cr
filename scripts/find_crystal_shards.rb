#!/usr/bin/env ruby
# Simple script to find Crystal shards using GitHub API
# This is a simplified version of the script referenced in the find-crystal-shards skill

require 'json'
require 'open3'

def search_github(query)
  # Use gh CLI to search GitHub
  cmd = "gh api -X GET search/repositories -f q='#{query} language:Crystal' -f per_page=10"
  stdout, stderr, status = Open3.capture3(cmd)

  if status.success?
    JSON.parse(stdout)
  else
    puts "Error searching GitHub: #{stderr}"
    nil
  end
end

def evaluate_shard(repo)
  name = repo['full_name']
  stars = repo['stargazers_count']
  updated = repo['updated_at']
  description = repo['description'] || ''

  puts "  #{name}"
  puts "    Stars: #{stars}, Updated: #{updated}"
  puts "    Description: #{description[0..100]}..."
  puts
end

if ARGV.empty?
  puts 'Usage: ruby scripts/find_crystal_shards.rb <query>'
  puts "Example: ruby scripts/find_crystal_shards.rb 'z3 solver'"
  exit 1
end

query = ARGV.join(' ')
puts "Searching for Crystal shards: #{query}"
puts

results = search_github(query)

if results && results['items']
  puts "Found #{results['total_count']} results. Top #{results['items'].size}:"
  puts
  results['items'].each do |repo|
    evaluate_shard(repo)
  end
else
  puts 'No results found or error occurred.'
end
