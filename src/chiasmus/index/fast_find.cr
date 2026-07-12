require "file_utils"
require "wait_group"
require "log"

module FastFind
  Log.setup_from_env

  Logger = ::Log.for(self)

  # Configuration for traversal
  class Config
    Logger = ::Log.for(self)
    # Configurable options for directory traversal
    property max_depth : Int32 = Int32::MAX
    property? follow_symlinks : Bool = false
    property? ignore_hidden : Bool = true
    property error_handler : Proc(Exception, Bool)? = nil

    def initialize
      @error_handler = ->(ex : Exception) do
        Logger.error { "Error in traversal: #{ex.message}" }
        false
      end
    end
  end

  # Represents a file/directory entry with metadata
  struct Entry
    getter path : Path
    getter metadata : File::Info?
    getter type : Symbol # :file, :directory, :symlink

    def initialize(@path : Path, @metadata : File::Info?, @type : Symbol)
    end

    def readable?
      if md = metadata
        md.readable?
      else
        false
      end
    end

    def file?
      @type == :file
    end

    def directory?
      @type == :directory
    end

    def symlink?
      @type == :symlink
    end
  end

  # High-performance directory walker
  class Walker
    Logger = Log.for(self)
    # Use a concurrent queue for efficient directory processing
    @queue : Channel(Entry)
    @config : Config
    @wait_group = WaitGroup.new

    def initialize(
      @paths : Array(String),
      @config : Config = Config.new,
    )
      @queue = Channel(Entry).new(capacity: 1024)
      Logger.debug { "Walker initiated with paths: #{@paths}" }
    end

    # Parallel directory traversal using Crystal's lightweight concurrency
    def walk
      spawn do
        @paths.each do |root_path|
          spawn do
            @wait_group.add(1)
            begin
              Logger.debug { " Processing directory #{root_path}" }
              process_directory(Path.new(root_path), 0)
            rescue ex
              Logger.error { "Error processing directory #{root_path}\n#{ex.message}" }
            ensure
              @wait_group.done
              Logger.debug { "Finished processing directory: #{root_path}" }
            end
          rescue ex
            Logger.error { "in outer spawn\n#{ex.message}\n\n" }
            next
          end
        end

        spawn do
          Logger.debug { "Waiting for all directory processing to complete" }
          @wait_group.wait
          Logger.debug { "All directory processing is complete - closing queue" }
          @queue.close
        end
      end
      @queue
    end

    private def process_directory(path : Path, depth : Int32)
      Logger.debug { "Entering directory: #{path}, depth: #{depth}" }

      return if depth > @config.max_depth

      return if @config.ignore_hidden? && path.basename.to_s.starts_with?('.')

      return unless File.directory? path

      return unless File::Info.readable? path

      begin
        Dir.each_child(path) do |child_name|
          process_child(path, child_name, depth)
        end
      rescue ex : IO::Error | File::Error
        Logger.warn { "Could not read directory #{path}\n #{ex.message}\n\n" }
        handle_error(ex)
      rescue ex
        Logger.error { "Unexpected error processing directory #{path}: #{ex.message}" }
        handle_error(ex)
      end
    end

    private def process_child(path : Path, name : String, depth : Int32)
      child_path = path / name

      Log.debug { "Processing child: #{child_path}" }

      metadata = File.info?(child_path, follow_symlinks: @config.follow_symlinks?)
    rescue ex
      Logger.warn { "Could not get metadata for #{child_path} #{ex.message}" }
    else
      return unless metadata

      entry_type = determine_entry_type(metadata)
      entry = Entry.new(child_path, metadata, entry_type)

      @queue.send(entry)

      return unless entry.directory?

      recurse_directory(child_path, depth)
    end

    private def recurse_directory(child_path : Path, depth : Int32)
      return unless File::Info.readable?(child_path)

      begin
        process_directory(child_path, depth + 1)
      rescue ex
        Logger.warn { "Could not process directory #{child_path}: #{ex.message}" }
      end
    end

    private def determine_entry_type(metadata : File::Info?) : Symbol
      return :unknown unless metadata
      case
      when metadata.directory? then :directory
      when metadata.symlink?   then :symlink
      when metadata.file?      then :file
      else                          :unknown
      end
    end

    private def handle_error(ex : Exception)
      if handler = @config.error_handler
        continue = handler.call(ex)
        raise ex unless continue
      end
    end
  end

  # Main interface for directory traversal
  def self.find(
    path : String | Path,
    config : Config = Config.new,
    & : Entry ->
  )
    walker = Walker.new([path.to_s], config)
    queue = walker.walk
    loop do
      begin
        entry = queue.receive?
        break if entry.nil?
        Logger.debug { "Received entry #{entry}" }
        yield entry
      rescue Channel::ClosedError
        break
      end
    end
  end

  # Main interface for directory traversal
  def self.find(
    paths : Array(String),
    config : Config = Config.new,
    & : Entry ->
  )
    walker = Walker.new(paths, config)
    queue = walker.walk
    loop do
      begin
        entry = queue.receive?
        break if entry.nil?
        Logger.debug { "Received entry #{entry}" }
        yield entry
      rescue Channel::ClosedError
        break
      end
    end
  end
end
