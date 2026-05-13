require "../src/chiasmus/discovery"

Chiasmus::Discovery.register_grammar_directory("vendor/grammars")

LANGUAGES = {
  "javascript" => Chiasmus::Discovery::JavaScriptExtractor.new,
  "python"     => Chiasmus::Discovery::PythonExtractor.new,
  "typescript" => Chiasmus::Discovery::TypeScriptExtractor.new,
  "ruby"       => Chiasmus::Discovery::RubyExtractor.new,
  "java"       => Chiasmus::Discovery::JavaExtractor.new,
}

LANGUAGES.each do |name, extractor|
  puts "=== #{name} ==="
  lang = Chiasmus::Discovery::GrammarLoader.load_language(name)
  unless lang
    puts "grammar not available"
    puts
    next
  end

  # Map language name to test file extension
  test_ext = case name
             when "javascript" then "js"
             when "typescript" then "tsx"
             when "python"     then "py"
             when "ruby"       then "rb"
             when "java"       then "java"
             else name
             end
  test_path = "vendor/codeium-parse/test_files/test.#{test_ext}"

  source = File.read(test_path)
  parser = TreeSitter::Parser.new(language: lang)
  tree = parser.parse(nil, source)
  items = extractor.extract(tree.root_node, source, "test.#{test_ext}")
  items.sort_by(&.id).each { |i| puts "#{i.kind}: #{i.name}" }
  puts "total: #{items.size}"
  puts
end
