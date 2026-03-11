# pi shim test extension notes

## Purpose

This note documents the test-only control path used by Symphony's real-pi shim integration tests.

The goal is to provide a generic channel for a pi extension command to send arbitrary test payloads back to Symphony without depending on LLM behavior.

The test extension reaches the shim indirectly through the shared shim client established by the generic extension over `PI_SHIM_SOCKET`, a Unix socket owned by the shim rather than a direct Symphony transport.

One current use of that channel is `/print-tools`, which reports the tool list observed by pi.

## Background

The `/print-tools` test command runs as a **pi extension command**.

According to pi's extension lifecycle docs:
- extension commands are checked first
- they can bypass normal agent processing
- `agent_start` / `turn_start` / `turn_end` / `agent_end` belong to the normal agent lifecycle

That means a successful `/print-tools` command is **not guaranteed** to produce a real pi `agent_end` event, even if the command itself completes successfully.

This matters because the shim currently treats real pi `agent_end` as the signal that a turn is complete.

## `push_to_symphony` shim control contract

To make extension-command test flows deterministic, the test-only `push_to_symphony` dynamic tool may return shim-private control metadata alongside its normal result payload.

Recommended shape:

```json
{
  "success": true,
  "payload": {"tools": [...]},
  "shim": {
    "cmd": "synthetic:agent_end"
  }
}
```

This `shim` object is **not** a pi instruction and **not** part of the public dynamic tool contract.
It is a shim-private testing control channel encapsulated inside the `push_to_symphony` result.

## Semantics

When the shim sees a `push_to_symphony` result containing:

```json
{"shim":{"cmd":"synthetic:agent_end"}}
```

it should:

1. still send the normal `tool_reply` back to the extension for the outstanding `tool_call`
2. intercept `result.shim.cmd == "synthetic:agent_end"` locally inside the shim
3. treat it as if pi had emitted the completion signal the shim is waiting for
4. run the same turn-completion logic used for a real pi `agent_end`
5. guard against double-completion if a real pi `agent_end` later arrives

## Important separation of concerns

`push_to_symphony.shim.cmd == "synthetic:agent_end"` affects **turn completion logic**, not the tool call protocol.

So there are two separate completions:

### 1. Tool call completion

The extension is waiting for:

```json
{"type":"tool_reply","id":"...","result":{...}}
```

The shim must continue to send that reply normally.

### 2. Turn completion

The AppServer / Codex-facing side of the shim is waiting for the equivalent of pi finishing the prompt.

`synthetic:agent_end` should satisfy that wait inside the shim, without requiring pi itself to emit a real `agent_end` event for this extension-command path.

## Non-goals

- Do not add `push_to_symphony` to generic public dynamic tool contracts.
- Do not claim that pi itself emitted `agent_end`.
- Do not forward `result.shim.cmd == "synthetic:agent_end"` outward as a normal application-level tool event.
- Do not rely on `ctx.shutdown()` or similar extension APIs to synthesize agent lifecycle events.

## Recommended implementation shape

Inside the shim's handling of extension-originated `tool_call` replies:

- inspect the returned `result`
- if `result.shim.cmd == "synthetic:agent_end"`, trigger the shim's existing turn-complete path
- then continue to deliver the normal `tool_reply` to the extension

A real pi `agent_end` should still work as usual. The shim should simply ignore any later duplicate completion if the turn is already settled.

## Why this exists

This keeps the test deterministic while preserving the main architectural rule:

- the shim remains passive for normal pi traffic
- but test-only extension-command flows get an explicit, documented control hook
