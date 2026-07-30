# Vendor Update Plan: Chiasmus `d1f1291`

## Scope and evidence

The vendor submodule advanced from `576ed38` (v0.1.24) to `d1f1291`
(upstream v0.1.26). The meaningful upstream feature is opt-in, local GGUF
embeddings. The final commit only removes a dead branch in the new model-URI
normalizer.

| Upstream area | Change | Crystal status | Required disposition |
|---|---|---|---|
| `src/config.ts` | `localEmbeddings` config block | Missing | Port the user-facing config schema and validation. |
| `src/llm/local-embeddings.ts` | Lazy, batched, single-flight local embedding adapter | Missing | Port behind a Crystal-native backend boundary. |
| `src/llm/anthropic.ts` | Local-first embedding selection, env/config resolution, fallback warning | Partial | Apply equivalent selection in Crystal's embedding resolver, not the vendor adapter factory. |
| `src/mcp-server.ts` | Pass config/home to embedding factory for formalization ranking | Partial | Wire the shared resolver into both search and `Formalize::Engine`. |
| `tests/config.test.ts` | Config parsing coverage | Missing | Port. |
| `tests/create-embedding-from-env.test.ts` | Local-priority and fallback coverage | Missing | Port against Crystal's resolver. |
| `tests/local-embeddings.test.ts` | Adapter lifecycle and batching coverage | Missing | Port against an injectable Crystal backend. |
| `package.json`, `pnpm-lock.yaml` | optional `node-llama-cpp` package | Intentional divergence | Do not add Node dependencies to the Crystal shard. |

Existing Crystal behavior is relevant but insufficient:

- `MCPServer::Tools::SearchTool` supports remote OpenAI/DeepSeek and local
  Ollama embeddings through Crig. It does not read `config.json`, does not
  recognize `CHIASMUS_LOCAL_EMBED*`, and defaults to an Ollama server rather
  than an in-process GGUF model.
- `Utils::Config::ChiasmusConfig` is currently empty, so the upstream
  `localEmbeddings` block cannot be represented or round-tripped.
- `Formalize::Engine` already accepts an optional embedding function, but
  `MCPServer::Server#with_agent` never resolves and injects one. The upstream
  update explicitly wires its resolved embedding adapter into formalization.
- Crig replaces upstream provider adapters. The Crystal port must preserve
  Crig as the common `EmbeddingModel` interface rather than porting
  `node-llama-cpp` or TypeScript adapter classes directly.

## Compatibility contract

The finished Crystal feature must provide the following observable behavior:

1. `~/.config/chiasmus/config.json` accepts:

   ```json
   {
     "localEmbeddings": {
       "enabled": true,
       "model": "hf:Qwen/Qwen3-Embedding-0.6B-GGUF",
       "dimension": 1024,
       "modelsDir": "/optional/models"
     }
   }
   ```

2. `CHIASMUS_LOCAL_EMBED` accepts `1`, `true`, `yes`, or `on`; model,
   dimension, model directory, and batch size have corresponding
   `CHIASMUS_LOCAL_EMBED_*` overrides. Environment values win per field.
3. When enabled with a model, local embeddings take precedence over explicit
   cloud embedding credentials. When enabled without a model, a clear warning
   is emitted and the existing Cloud/Ollama resolution proceeds unchanged.
4. The local adapter loads once on first non-empty embedding request, batches
   requests (default 32), shares concurrent initialization, retries after a
   failed load, and releases its session at shutdown.
5. Search cache partitioning has a stable dimension before opening a cache.
   Because Crig's `EmbeddingModel#ndims` is eager, either the local backend
   must discover dimension during initialization or configuration must require
   `dimension`; do not silently create a cache with an invalid dimension.
6. The same resolved embedding capability is available to both
   `chiasmus_search` and `Formalize::Engine` template re-ranking.

## Implementation plan

### P28.1 — Establish the Crystal-native local backend (decision gate)

1. Evaluate a maintained Crystal-compatible local GGUF backend: a native
   llama.cpp binding/FFI, a bundled executable bridge, or an existing Crig
   extension. Prefer a backend that can implement `Crig::Embeddings::EmbeddingModel`
   without requiring an Ollama daemon.
2. Record the selected backend, licensing, model-download/cache behavior,
   supported platforms, and release packaging in this plan before adding a
   dependency.
3. If no safe in-process backend is available, implement the config and
   selection layer but leave GGUF selection disabled with an actionable error;
   do not misrepresent the existing Ollama server integration as in-process
   local embeddings.
4. Define a small injectable `LocalEmbeddingSession` contract before the
   production adapter so lifecycle tests do not download a model.

**Acceptance:** the selected implementation satisfies the compatibility
contract's no-daemon requirement, or the documented fallback decision is
explicit and tested.

### P28.2 — Add configuration and deterministic resolution

1. Extend `Utils::Config::ChiasmusConfig` with a nested
   `LocalEmbeddingsConfig`, mapping the JSON field name `localEmbeddings` and
   its camelCase members (`modelsDir`). Preserve tolerant loading: malformed
   blocks do not prevent server startup.
2. Add a shared embedding-resolution module instead of keeping provider
   precedence inside `SearchTool`. It should return a typed resolution for
   `local`, `ollama`, `openai`, and `deepseek`, or no provider.
3. Merge config and environment fields deterministically. Local enabled state
   is the OR of config and truthy env flag; environment overrides model,
   dimension, directory, and batch size.
4. Preserve the current explicit `CHIASMUS_EMBED_PROVIDER` semantics below
   the local branch. Do not change existing OpenAI, DeepSeek, or Ollama
   defaults while adding the new local priority.

**RED specs:**

- default/malformed config behavior;
- complete config block round-trip;
- non-boolean `enabled` and invalid fields;
- truthy/falsy env parsing and per-field overrides;
- local precedence over a cloud key;
- enabled-without-model warning and fallback.

### P28.3 — Implement the adapter behind Crig's interface

1. Add the local embedding adapter under `src/chiasmus/search/` (or a focused
   `llm/` module only if it remains independent of MCP tools).
2. Adapt it to `Crig::Embeddings::EmbeddingModel`; retain Crig for all callers
   and avoid a second vector type.
3. Implement lazy initialization, empty-input fast path, bounded batch calls,
   single-flight initialization across fibers, retry after failed initialization,
   eager/configured dimension handling, and disposal.
4. Normalize model identifiers consistently with upstream: accept `hf:`,
   HTTP(S), existing local paths, and bare Hugging Face IDs. Place downloaded
   models under `$CHIASMUS_HOME/models` unless overridden.
5. Ensure blocking model setup and embedding calls run through spawned/channel
   boundaries so MCP fibers remain responsive.

**RED specs:** inject a fake session/loader to cover lazy load, one shared
load under concurrent calls, retry, empty input, batching, dimension discovery,
and disposal. No CI spec may download a GGUF model.

### P28.4 — Wire search and formalization consistently

1. Replace `SearchTool`'s private provider factory with the shared resolver.
   Keep `embedding_configured?` aligned with actual resolvability so MCP tool
   gating does not hide a configured local backend.
2. Resolve configuration using `Utils::Config.load(Utils::Config.chiasmus_home)`
   once per server lifecycle, not per query, while keeping test injection
   possible.
3. Convert the resolved Crig embedding model into `Formalize::EmbedFn` and
   inject it from `Server#with_agent`; retain BM25 fallback on embedding
   initialization or runtime failures.
4. Keep cache names dimension-specific and preserve the existing atomic,
   SHA-256 embedding cache behavior.

**RED specs:**

- local resolution makes `chiasmus_search` available without cloud keys;
- local configuration is passed into search and formalization;
- formalization falls back to BM25 after local embedding failure;
- current explicit provider and no-provider tool-gating behavior remains
  unchanged.

### P28.5 — Documentation, parity ledger, and release checks

1. Document Crystal-native local embedding setup, supported platforms/model
   source, cache path, all `CHIASMUS_LOCAL_EMBED_*` variables, priority rules,
   and how it differs from upstream `node-llama-cpp` packaging.
2. Update `plans/parity.md` from vendor `576ed38` to `d1f1291`, add P28, and
   record the Node package itself as an intentional implementation divergence.
3. Append new source/test identifiers to the curated TypeScript inventory with
   explicit target symbols, specs, and divergence rationale. Refresh generated
   manifests only with the canonical parity skill scripts; do not overwrite
   existing curated mappings.
4. Run `make format`, `make lint`, `make test`, the relevant MCP integration
   specs, and the parity inventory/source/test drift checks. Run one manual
   local-backend smoke test only when a model is explicitly configured.

## Out of scope

- Porting `node-llama-cpp`, `pnpm-lock.yaml`, or Node optional-dependency
  mechanics verbatim.
- Altering the existing Crig LLM-provider factory solely to mirror TypeScript
  adapter classes.
- Changing vector-search ranking, cache schema, or cloud-provider priority
  beyond the new documented local-first branch.

## Completion criteria

- All P28 RED specs are green without network/model downloads in CI.
- `chiasmus_search` and formalization use the same configured local resolver.
- Local enabled-without-model is diagnosable and safely falls back.
- Existing cloud/Ollama search behavior is regression-tested.
- The parity ledger marks each upstream source/test addition as ported or
  intentional divergence with a concrete rationale.
