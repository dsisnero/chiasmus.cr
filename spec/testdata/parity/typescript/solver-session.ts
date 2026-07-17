// Derived from vendor/chiasmus/src/solvers/session.ts to isolate the class
// method surface relevant to parity: create, solve, and dispose.
type SolverInput = { spec: string };
type SolverResult = { ok: boolean };

export class SolverSession {
  static create(): SolverSession {
    return new SolverSession();
  }

  async solve(_input: SolverInput): Promise<SolverResult> {
    return { ok: true };
  }

  dispose(): void {
  }
}
