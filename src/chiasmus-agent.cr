require "./chiasmus"

begin
  opts = Chiasmus::AgentCLI.parse(ARGV)
rescue ex : OptionParser::Exception
  exit 0
end

q = opts.question || ""

case opts.mode
when :ask
  if !opts.code_files.empty?
    result = Chiasmus::AgentCLI.run_graph_analysis(opts.code_files, q)
    puts Chiasmus::AgentCLI.format_output(result, json: opts.json?)
  else
    agent = Chiasmus::AgentCLI.build_agent(opts)
    result = Chiasmus::AgentCLI.run_formal_solve(q, agent, opts.debug?)
    puts Chiasmus::AgentCLI.format_output(result, json: opts.json?)
  end
when :repl
  agent = Chiasmus::AgentCLI.build_agent(opts)
  Chiasmus::AgentCLI.run_repl(agent, opts)
end
