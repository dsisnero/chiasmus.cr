module Chiasmus
  module Utils
    module AtomicFile
      extend self

      def write(path : String, content : String) : Nil
        tmp = "#{path}.tmp.#{Random::Secure.hex(8)}"
        begin
          dir = File.dirname(path)
          Dir.mkdir_p(dir) unless Dir.exists?(dir)
          File.write(tmp, content)
          File.rename(tmp, path)
        rescue ex
          begin
            File.delete(tmp) if File.exists?(tmp)
          rescue
          end
          raise ex
        end
      end
    end
  end
end
