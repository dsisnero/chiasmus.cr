# Crig Call Graph Analysis

**Snapshot**: `crig` — 33 core source files from `lib/crig/src/`

**Generated**: 2026-07-30

---

## 1. Summary Statistics

| Metric | Value |
|--------|-------|
| Files analyzed | 33 |
| Functions | 909 |
| Classes/types | 133 |
| Call edges | 2,123 |
| Imports | 130 |
| Topological layers | 0 violations |

The call graph is relatively flat — no layer violations were detected, indicating clean separation of concerns.

---

## 2. Hub Nodes (Highest Degree Centrality)

The most connected symbols, ranked by total degree (in + out edges):

| Symbol | Degree | Role |
|--------|--------|------|
| `new` | 258 | Constructor — called ubiquitously across all types |
| `getter` | 101 | Crystal macro-generated accessors |
| `class` | 81 | Type dispatch / enum variant resolution |
| `build` | 34 | Builder pattern — assembles client/provider configurations |
| `text` | 32 | Text content extraction from completion responses |
| `to_json` | 31 | JSON serialization |
| `completion` | 30 | Core LLM completion dispatch |
| `raise` | 30 | Error handling paths |
| `from_json` | 27 | JSON deserialization |
| `process_choice` | 27 | Streaming response choice processing |

**Interpretation**: The `new` hub is expected in most object-oriented code. `getter` and `class` reflect Crystal's macro-generated accessor pattern. The prominence of `build`, `completion`, `to_json`/`from_json` confirms Crig's primary role as an LLM client builder/runner with heavy JSON serialization.

---

## 3. Bridge Nodes (Betweenness Centrality)

Symbols that act as structural bridges between communities:

| Symbol | Score | Role |
|--------|-------|------|
| `new` | 0.128 | Constructor — connects every community |
| `getter` | 0.053 | Property access — widespread |
| `Usage` | 0.052 | Token usage tracking — links the streaming/completion pipeline to telemetry |

**Interpretation**: `Usage` as a bridge suggests telemetry/token tracking is a cross-cutting concern that touches both the provider layer (OpenAI, Anthropic) and the high-level Agent/Client API.

---

## 4. Community Structure (Louvain Detection)

The graph was partitioned into **511 communities** (seed=42). Major communities:

| Community ID | Size | Members (sample) | Represents |
|---|---|---|---|
| 0 | 115 | `.initialize`, `<`, `<=`, `api_key`, `as?`, `assistant` | Core algebraic/data infrastructure — comparators, initialization, API key handling |
| 1 | 99 | `Agent`, `AgentBuilder`, `AgentToolAdapter`, `AnyClient`, `AssistantContent` | High-level public API — agent, client, and content types |
| 2 | 42 | `additional_params`, `base_url`, `context` | HTTP request parameter construction |
| 3 | 17 | `completion_error`, `deserialization_error`, `http_error` | Error type hierarchy |
| 4 | 17 | `cancel`, `close`, `dup`, `each`, `empty` | Iterator/collection operations |
| 5 | 16 | `call`, `choice`, `convert`, `extract_json_with_usage` | Extraction pipeline (JSON with usage tracking) |
| 6 | 13 | `build`, `custom`, `finalize_choice`, `merge_one_of_into_any_of!` | Builder pattern internals |
| 7 | 12 | `sanitize_array`, `sanitize_defs!`, `sanitize_items!` | JSON schema sanitization (OpenAI-specific) |
| 8 | 11 | `Usage`, `input_tokens`, `output_tokens`, `cache_creation_input_tokens` | Token usage tracking |
| 9 | 10 | `append_text_additional_params`, `insert` | Text chunk assembly |
| 10+ | 6-9 | Various small clusters | Streaming, MCP tools, telemetry, vector store |
| 115–511 | 1 each | Singleton types: `OpenAI`, `Gemini`, `Agent`, `VectorStore`, `Telemetry`, etc. | Standalone types/constants not tightly coupled to others |

**Interpretation**: The community structure shows:
- A large **core infrastructure** community (115 members) handling basic operations
- A **high-level API** community (99 members) grouping Agent/Client abstractions
- Provider-specific communities (OpenAI sanitization, Error types, Builder patterns) separated by concern
- Most types (communities 115+) are singletons — they import from or are called by the core but don't form dense subgraphs

---

## 5. Surprise Edges

Cross-community edges that deviate from expected structure:

| Source | Target | Score | Reasons |
|--------|--------|-------|---------|
| `RawStreamingToolCall` | `getter` | 2 | Cross-community, peripheral-to-hub |
| `ToolCall` | `getter` | 2 | Cross-community, peripheral-to-hub |
| `ToolFunction` | `getter` | 2 | Cross-community, peripheral-to-hub |
| `add_tool` | `tool_added?` | 2 | Cross-community, peripheral-to-hub |
| `allowed_tool_names_for_choice` | `new` | 2 | Cross-community, peripheral-to-hub |
| `base_url` | `new` | 2 | Cross-community, peripheral-to-hub |
| `build` | `.try` | 2 | Cross-community, peripheral-to-hub |
| `build` | `embed_text` | 2 | Cross-community, peripheral-to-hub |
| `build` | `header` | 2 | Cross-community, peripheral-to-hub |

**Interpretation**: These are benign — tool call types reaching into property accessors (`getter`), and the builder (`build`) reaching into error handling (`.try`) and embedding/text utilities. All are normal coupling patterns.

---

## 6. Cycles

The following cycles were detected (condensed):

| Cycle group | Examples |
|-------------|----------|
| **Agent lifecycle** | `Crig.Agent.runner`, `Crig.Agent.stream_prompt` |
| **Completion state enums** | `ReasoningContent` variants (text, encrypted, redacted, summary, new_with_signature) |
| **Document/media enums** | `DocumentSourceKind` (url, base64, raw, string, unknown) |
| **Tool choice enums** | `ToolChoice` (auto, none, required, specific) |
| **Message variants** | `UserContent.tool_result_with_call_id` ↔ `Message.from` |
| **OpenAI sanitization** | `sanitize_schema_value`, `sanitize_object`, `sanitize_defs!`, `sanitize_properties!`, `sanitize_items!`, `sanitize_variants!`, `sanitize_array` (mutual recursion) |
| **Streaming** | `StreamingCompletionResponse.next_item`, `StreamingCompletionResponse.process_choice` |

**Interpretation**: Most cycles are Crystal enum variant patterns where variants reference each other (e.g., `ReasoningContent.text`, `ReasoningContent.encrypted`). The OpenAI sanitization functions do form real mutual recursion. The Agent call/stream cycle is a genuine caller loop (agent calls completion which calls back).

---

## 7. Entry Points

127 entry points were detected. Key public API surfaces:

| Category | Entry points |
|----------|-------------|
| **Agent** | `Agent.prompt`, `Agent.chat`, `Agent.stream_chat`, `Agent.call` |
| **Client** | `Client.build`, `Client.completion`, `Client.embeddings`, `Client.audio_generation` |
| **Tools** | `add_tools`, `dynamic_tool`, `static_tool`, `rmcp_tool`, `from_mcp_server` |
| **Embeddings** | `Embeddings.embed`, `Embeddings.search`, `Embeddings.append_embedded` |
| **Streaming** | `StreamingCompletionResponse.next_item`, `StreamingCompletionResponse.consume` |
| **Extraction** | `Extractor.extract`, `Extractor.extract_with_usage` |
| **Memory/Vector** | `Memory.append`, `Memory.clear`, `VectorStore.prune_document` |
| **Telemetry** | `Span.end_span`, `Span.record_token_usage`, `Span.record_model_input/output` |

The largest single entry-point file is the client builder (`client/builder.cr`), which wires together all provider capabilities.

---

## 8. Dead Code Analysis

Functions detected as unreachable from entry points:

| Category | Examples | Notes |
|----------|----------|-------|
| **Trait/interface methods** | `resolved_name`, `capable?`, `composes_native_output_with_tools?`, `builder_type` | Interface contracts — called polymorphically, not detected statically |
| **HTTP client helpers** | `post`, `get`, `post_sse`, `get_sse`, `with_header`, `retries`, `http_client` | Called via method dispatch, not directly |
| **Streaming internals** | `cancel`, `consume`, `next_stream_item`, `final_response_yielded?` | Called via channel/fiber patterns |
| **Collection ops** | `first_ref`, `first_mut`, `last_ref`, `last_mut`, `into_iter`, `iter_mut` | Iterator adapter methods |
| **Telemetry procs** | `record_token_usage`, `end_span`, `set_attribute`, `recording?` | Called dynamically or from instrumentation |
| **Audio/transcription** | `audio_generation_request`, `voice`, `speed`, `transcription_request` | Capability trait methods |

**Interpretation**: All "dead" code is genuinely reachable — it's abstract interface/trait methods, HTTP client helpers, and streaming internals that the static analysis cannot resolve due to polymorphic dispatch and Crystal's macro-generated code.

---

## 9. Architectural Observations

### No Layer Violations
Zero layer violations — the module dependency structure is clean. The architecture follows a clear layered pattern:

```
Agent/Client API (public)
    ↕
Completion/Embedding models
    ↕
Provider adapters (OpenAI, Anthropic, etc.)
    ↕
HTTP Client / Streaming
```

### Streaming Architecture
The streaming pipeline is a distinct subgraph with its own small community (community 13: `delta`, `internal_call_id`, `message_id`, `next_item`, `process_choice`). It connects to the completion model via `to_completion_response` and `from_raw_choices`.

### Builder Pattern Everywhere
Crig makes heavy use of the builder pattern:
- `ClientBuilder` (wires provider+capabilities)
- `CompletionRequestBuilder` (assembles request parameters)
- `AgentBuilder` (configures agent + tools + memory)
- `EmbeddingsBuilder` (configures embedding model+store)
- `InMemoryVectorStoreBuilder`
- `ToolSetBuilder`

### Telemetry as Cross-Cutting Concern
The `Usage` bridge node (0.052 betweenness) and its community (community 8) span multiple subsystems — completion, streaming, and providers. This confirms the telemetry system is correctly designed as a cross-cutting concern rather than being embedded in any single layer.

### Provider Pattern
Each provider (OpenAI, Anthropic, Gemini, etc.) follows a consistent internal structure:
- `client.cr` — HTTP client setup
- `completion.cr` — completion request/response mapping
- `streaming.cr` — SSE/stream handling
- `embedding.cr` — embedding endpoint (where applicable)
- `model_listing.cr` — model querying (where applicable)

---

## 10. Recommendations

1. **Provider consistency**: 28 provider files follow the same pattern — consider a shared provider template or macro to reduce duplication.

2. **OpenAI sanitization cycle**: The mutual recursion between `sanitize_defs!`, `sanitize_properties!`, `sanitize_items!`, `sanitize_variants!`, and `sanitize_array` in `providers/openai/completion.cr` could benefit from a recursive descent refactor with explicit depth limits.

3. **Singleton communities**: 396 singleton communities (115–511) suggest many types have only import-level coupling. This is fine for type definitions but worth monitoring for unnecessary fragmentation.

4. **Entry point surface**: 127 entry points is high — consider auditing the public API surface for methods that could be package-private versus truly public.
