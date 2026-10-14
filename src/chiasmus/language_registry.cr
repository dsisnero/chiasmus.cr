module Chiasmus
  # Shared language file and grammar directory registry for the command-line tools.
  module LanguageRegistry
    LANGUAGE_EXTENSIONS = {
      "python"     => [".py"],
      "ruby"       => [".rb"],
      "java"       => [".java"],
      "go"         => [".go"],
      "rust"       => [".rs"],
      "scala"      => [".scala"],
      "crystal"    => [".cr"],
      "javascript" => [".js"],
      "typescript" => [".ts"],
      "tsx"        => [".tsx"],
      "c"          => [".c", ".h"],
      "cpp"        => [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"],
      "csharp"     => [".cs"],
      "bash"       => [".sh"],
      "dart"       => [".dart"],
      "kotlin"     => [".kt", ".kts"],
      "perl"       => [".pl", ".pm"],
      "php"        => [".php"],
      "proto"      => [".proto"],
    }

    extend self

    def extensions(language : String) : Array(String)
      LANGUAGE_EXTENSIONS[language]? || [".#{language}"]
    end

    def grammar_directories(scan_dir : String, include_current_directory_vendor : Bool = false) : Array(String)
      dirs = [] of String

      env_dir = ENV["CHIASMUS_GRAMMAR_DIR"]?
      dirs << env_dir if env_dir && Dir.exists?(env_dir)

      bundled_dirs.each do |path|
        dirs << path if Dir.exists?(path)
      end

      vendor_dir = File.join(scan_dir, "vendor", "grammars")
      dirs << vendor_dir if Dir.exists?(vendor_dir)

      if include_current_directory_vendor
        repo_vendor = File.join(".", "vendor", "grammars")
        dirs << repo_vendor if Dir.exists?(repo_vendor)
      end

      dirs.uniq
    end

    private def bundled_dirs : Array(String)
      executable = File.expand_path(PROGRAM_NAME)
      executable_dir = File.dirname(executable)

      [
        File.join(executable_dir, "grammars"),
        File.join(executable_dir, "..", "grammars"),
      ].map { |path| File.expand_path(path) }
    end
  end
end
