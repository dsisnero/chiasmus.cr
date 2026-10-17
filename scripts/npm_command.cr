module NpmCommand
  # Windows installs npm and npx as command scripts, which Process.run cannot
  # launch directly. Route those invocations through cmd.exe while keeping the
  # argument list intact for native executables on other platforms.
  def self.invocation(executable : String, arguments : Array(String), windows : Bool = {% if flag?(:win32) %} true {% else %} false {% end %}) : Tuple(String, Array(String))
    if windows && {"npm", "npx"}.includes?(executable)
      {ENV["COMSPEC"]? || "cmd.exe", ["/c", executable] + arguments}
    else
      {executable, arguments}
    end
  end

  def self.run(executable : String, arguments : Array(String), *, output : Process::Redirect = Process::Redirect::Inherit, error : Process::Redirect = Process::Redirect::Inherit) : Process::Status
    command, command_arguments = invocation(executable, arguments)
    Process.run(command, command_arguments, output: output, error: error)
  end
end
