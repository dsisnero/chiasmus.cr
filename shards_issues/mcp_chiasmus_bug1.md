# MCP ReadBuffer Truncates Fragmented Second Message During MCP stdio Session

## Summary

Yes, this is still an `mcp` bug.

After updating this repo to `crig 0.40.0` and allowing `crig` to pull in its
current `mcp` dependency, the installed `mcp` code still reproduces the same
failure mode: `MCP::Shared::ReadBuffer` can parse a partial second JSON-RPC
message as though it were complete if the first message has already left a
newline in the underlying `IO::Memory` buffer.

In practice, this breaks MCP stdio sessions where:

1. `initialize` succeeds.
2. The next server response, commonly `tools/list`, is large enough to arrive in
   multiple chunks.
3. `ReadBuffer#read_message` sees the newline from the already-consumed first
   message and attempts to parse a truncated second message.

The observed error is:

```text
Unhandled exception: Unterminated string at line 1, column 8001 (JSON::ParseException)
...
from lib/mcp/src/mcp/shared/read_buffer.cr:26:7 in 'read_message'
```

This is consistent with the earlier Chiasmus/Codex MCP tool-discovery failure:
`initialize` worked, but `tools/list` never completed successfully.

## Current Dependency State

Host project state on June 28, 2026:

- `crig` updated from `0.39.0` to `0.40.0`
- direct top-level `mcp` dependency removed from `shard.yml`
- `shard.lock` now resolves:
  - `crig` to `0.40.0`
  - `mcp` to `0.5.6`

Relevant files:

- [shard.yml](/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr/shard.yml)
- [shard.lock](/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr/shard.lock)
- [lib/crig/shard.yml](/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr/lib/crig/shard.yml)
- [lib/mcp/src/mcp/shared/read_buffer.cr](/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr/lib/mcp/src/mcp/shared/read_buffer.cr)

Despite `mcp` resolving to `0.5.6`, the installed `ReadBuffer` implementation
still uses the old logic:

- checks for `\n` against the entire backing slice
- does not limit the scan to unread bytes
- does not compact consumed bytes after `gets`

## Why This Is an MCP Bug and Not a Chiasmus Bug

The failure reproduces at the library level without starting the Chiasmus MCP
server.

The bug can be demonstrated using only:

- `MCP::Shared::ReadBuffer`
- a valid first JSON-RPC response
- a valid second JSON-RPC response split into two chunks

Chiasmus is only the host application that triggers the condition because its
`tools/list` response is large enough to be fragmented.

## Minimal Reproduction

Run from the Chiasmus repo root with the currently installed `lib/mcp`:

```bash
/bin/zsh -lc '
tmp=/tmp/mcp-current-read-buffer-repro.cr
rm -f "$tmp"
printf "%s\n" \
  "require \"mcp\"" \
  "buffer = MCP::Shared::ReadBuffer.new" \
  "first = MCP::Protocol::JSONRPCResponse.new(" \
  "  id: 1_i64," \
  "  result: MCP::Protocol::InitializeResult.new(" \
  "    protocol_version: \"2025-06-18\"," \
  "    capabilities: MCP::Protocol::ServerCapabilities.new," \
  "    server_info: MCP::Protocol::Implementation.new(name: \"test\", version: \"0.0.1\")" \
  "  )" \
  ")" \
  "second = MCP::Protocol::JSONRPCResponse.new(" \
  "  id: 2_i64," \
  "  result: MCP::Protocol::ListToolsResult.new(" \
  "    tools: [" \
  "      MCP::Protocol::Tool.new(" \
  "        name: \"tool\"," \
  "        description: \"x\" * 10_000," \
  "        input_schema: MCP::Protocol::Tool::Input.new(" \
  "          properties: {\"files\" => JSON.parse(%({\"type\":\"array\",\"items\":{\"type\":\"string\"}}))}," \
  "          required: [\"files\"]" \
  "        )" \
  "      )," \
  "    ]" \
  "  )" \
  ")" \
  "buffer.append(first.to_json)" \
  "buffer.append(\"\\n\")" \
  "raise \"first mismatch\" unless buffer.read_message.to_json == first.to_json" \
  "partial_second = second.to_json[0, 8_000]" \
  "buffer.append(partial_second)" \
  "raise \"expected nil after partial second\" unless buffer.read_message.nil?" \
  "buffer.append(second.to_json[8_000..])" \
  "buffer.append(\"\\n\")" \
  "msg = buffer.read_message" \
  "puts({status: \"ok\", second_matches: msg.to_json == second.to_json}.to_json)" \
  > "$tmp"
CRYSTAL_PATH="$PWD/lib/mcp/src:$(crystal env CRYSTAL_PATH)" \
CRYSTAL_CACHE_DIR=/private/tmp/mcp-current-read-buffer \
crystal run "$tmp"
'
```

## Expected Behavior

After appending only a partial second message, `buffer.read_message` should
return `nil`.

After the rest of the second message and its newline are appended,
`buffer.read_message` should return the full second message.

## Actual Behavior

After the first message is read, the consumed newline remains detectable in the
backing `IO::Memory` slice. When a partial second message is appended,
`ReadBuffer#read_message` sees that stale newline, calls `gets`, and passes an
incomplete JSON string to `JSONRPCMessage.from_json`, which raises:

```text
Unhandled exception: Unterminated string at line 1, column 8001 (JSON::ParseException)
```

## Root Cause

Current `ReadBuffer#read_message` behavior is effectively:

1. inspect `@buffer.to_slice`
2. search that full slice for `\n`
3. if any newline exists anywhere in the backing store, call `@buffer.gets`
4. parse the returned string as a full JSON-RPC message

That is incorrect once the current `IO::Memory#pos` has advanced past already
consumed bytes. At that point:

- the full slice still contains old bytes
- the old newline is still present
- the unread region may not yet contain a newline

The newline check therefore answers the wrong question.

The implementation also leaves consumed bytes in the buffer, which increases the
chance of repeated false positives on subsequent reads.

## Confirmed Fix Shape

A minimal fix that has already been validated in a clean `mcp.cr` fork does two
things:

1. search only the unread suffix `slice[pos, size - pos]` for `\n`
2. compact consumed bytes after `gets`

That fix was validated with:

- a focused failing-first regression spec
- a passing focused shard spec after the patch
- host-level verification that a fragmented `tools/list` response succeeds

## Host-Level Impact in Chiasmus

This bug manifests in Chiasmus because its MCP `tools/list` payload is large
enough to be fragmented in stdio transport.

Observed host symptom:

- MCP session starts
- `initialize` succeeds
- tool discovery stalls or fails because the next response is parsed
  prematurely

This was the root cause behind the earlier “Chiasmus tools are configured but do
not show up in Codex” behavior.

## Important Non-Root-Cause Note

The host project currently also has an unrelated compile error in
[src/chiasmus/mcp_server/server.cr](/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr/src/chiasmus/mcp_server/server.cr)
involving `Channel(Bool)` vs `Channel(Nil)` for `cancellation_signal`.

That is separate from this `mcp` bug and does not affect the reproduction above.

## Recommendation

Treat this as an upstream `mcp.cr` library bug.

Recommended upstream action:

1. add a regression spec for fragmented second-message handling in
   `spec/shared/read_buffer_spec.cr`
2. update `src/mcp/shared/read_buffer.cr` to:
   - scan only unread bytes for newline detection
   - compact consumed bytes after successful line extraction
3. cut a release including the fix
4. refresh the Chiasmus lockfile after the fix is published
