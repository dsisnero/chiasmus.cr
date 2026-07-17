module Chiasmus
  module Utils
    module AtomicFile
      extend self

      def write(path : String, content : String) : Nil
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        tmp = nil.as(String?)
        tmp = "#{path}.tmp.#{Random::Secure.hex(8)}"
        File.write(tmp, content)
        File.rename(tmp, path)
      rescue ex
        begin
          File.delete(tmp) if tmp && File.exists?(tmp)
        rescue
        end
        raise ex
      end
    end
  end
end
