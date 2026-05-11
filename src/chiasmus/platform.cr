module Chiasmus
  # Cross-platform abstractions for shared libraries, paths, and executables.
  module Platform
    extend self

    # Native shared library file extension for the current platform.
    def shared_library_extension : String
      {% if flag?(:darwin) %}
        "dylib"
      {% elsif flag?(:win32) %}
        "dll"
      {% else %}
        "so"
      {% end %}
    end

    # Library filename prefix (lib on unix, empty on Windows).
    def library_prefix : String
      {% if flag?(:win32) %}
        ""
      {% else %}
        "lib"
      {% end %}
    end

    # Executable file extension (.exe on Windows, empty elsewhere).
    def executable_extension : String
      {% if flag?(:win32) %}
        ".exe"
      {% else %}
        ""
      {% end %}
    end

    # Full library filename: libtree-sitter-{lang}.{ext}
    def grammar_library_name(language : String) : String
      "#{library_prefix}tree-sitter-#{language}.#{shared_library_extension}"
    end

    # Crystal linker flag for dynamic loading.
    def dlopen_flags : Int32
      {% if flag?(:win32) %}
        LibC::RTLD_LAZY
      {% else %}
        LibC::RTLD_LAZY | LibC::RTLD_LOCAL
      {% end %}
    end

    # Operating system name for artifact naming.
    def os_name : String
      {% if flag?(:darwin) %}
        "macos"
      {% elsif flag?(:win32) %}
        "windows"
      {% else %}
        "linux"
      {% end %}
    end

    # CPU architecture for artifact naming.
    def arch_name : String
      {% if flag?(:aarch64) || flag?(:arm64) %}
        "aarch64"
      {% elsif flag?(:x86_64) %}
        "x86_64"
      {% else %}
        "unknown"
      {% end %}
    end

    # Check if we are on a unix-like system (macOS or Linux).
    def unix? : Bool
      {% if flag?(:unix) %}
        true
      {% else %}
        false
      {% end %}
    end
  end
end
