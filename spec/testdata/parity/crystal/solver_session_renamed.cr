class SolverSession
  alias SolverInput = NamedTuple(spec: String)
  alias SolverResult = NamedTuple(ok: Bool)

  def self.create : self
    new
  end

  def run(_input : SolverInput) : SolverResult
    {ok: true}
  end

  def dispose : Nil
  end
end
