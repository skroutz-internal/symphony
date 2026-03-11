# pi-codex-shim Design

## Prime Directive

**Symphony sees the shim as Codex.**

Every message in and out of the shim follows the Codex JSON-RPC protocol exactly.
Symphony cannot tell whether it is talking to Codex or the shim. This is the invariant
that must never be broken.

---

## Overview

The shim bridges two worlds:

- **Left side (Symphony-facing):** speaks the Codex JSON-RPC protocol over stdin/stdout
- **Right side (pi-facing):** speaks a custom newline-delimited JSON protocol over a Unix domain socket

```
Symphony ──(Codex JSON-RPC)──► shim ──(socket)──► pi extension
Symphony ◄─(Codex JSON-RPC)── shim ◄─(socket)─── pi extension
```

The shim itself lives at:

- `pi-codex-shim.ts`

---

## Lifecycle

### 1. Shim starts

The shim begins reading Codex messages from stdin.

### 2. `initialize` (Symphony → shim)

Symphony sends the standard Codex `initialize` message.

The shim:
- replies with the standard Codex `initialize` ACK
- waits for the follow-up `initialized` notification

No pi process is started yet.

### 3. `thread/start` (Symphony → shim)

Symphony starts a Codex thread once per agent session / issue.

This is where the real Codex integration establishes long-lived per-thread state, and the
shim mirrors that behavior.

The shim:
1. stores the `dynamicTools` list from `thread/start`
2. creates a per-thread Unix domain socket server at `/tmp/pi-shim-<shim-pid>-<ts>.sock`
3. spawns a long-lived pi process (`pi --mode rpc ...`) for that thread and passes
   `PI_SHIM_SOCKET=<socket-path>` in the pi process environment
4. waits for pi extensions to connect to the socket
5. performs a **ping/pong handshake** on each accepted connection:
   ```
   shim → socket: {"type":"ping","id":"<uuid>"}
   ext  → socket: {"type":"pong","id":"<uuid>"}
   ```
6. forwards the stored `dynamicTools` to the connected extension:
   ```
   shim → socket: {"type":"tools","tools":[...]}
   ```
7. ACKs `thread/start` to Symphony

The generic project extension (`.pi/extensions/shim-extention.ts`) connects on `session_start`,
performs the handshake once, receives the tools, and registers them with pi via `pi.registerTool()`.

The test-only extension (`elixir/test/support/pi_extensions/push_to_symphony.ts`) does not open its
own socket connection. Instead, it reuses the shared shim client established by the generic
extension and invokes the registered `push_to_symphony` tool through that existing channel.

**The pi process and socket stay alive across multiple `turn/start` calls in the same thread.**

### 4. `turn/start` (Symphony → shim)

Symphony signals the start of a new turn within the existing thread.

The shim:
1. extracts the text input for the turn
2. sends that prompt to the already-running pi process
3. ACKs `turn/start` to Symphony
4. waits for turn completion
5. sends `turn/completed` (or `turn/failed`) back to Symphony

This matches the real Codex integration: **one long-lived thread session, multiple turns**.

### 5. Dynamic tool calls

When pi calls a dynamic tool, the extension forwards that call over the socket.

```
pi calls tool
  → extension sends:
        {"type":"tool_call","name":"<tool>","args":{...},"id":"<uuid>"}

  → shim receives socket message
  → shim sends to Symphony:
        {"id":"<uuid>","method":"item/tool/call","params":{"name":"<tool>","arguments":{...}}}

  → Symphony executes the tool
  → Symphony replies to shim:
        {"id":"<uuid>","result":{...}}

  → shim replies to extension:
        {"type":"tool_reply","id":"<uuid>","result":{...}}
```

The shim does not currently implement extra shim-local dynamic tools. The extension sees the
`dynamicTools` supplied by Symphony, plus whatever pi already has from its own built-in toolset.

### 6. Synthetic completion for `push_to_symphony`

There is one documented test-only control path: `push_to_symphony` may return shim-private metadata:

```json
{
  "success": true,
  "payload": {...},
  "shim": {
    "cmd": "synthetic:agent_end"
  }
}
```

When the shim sees:

```json
{"shim":{"cmd":"synthetic:agent_end"}}
```

inside the result for `push_to_symphony`, it:
1. still sends the normal `tool_reply` back to the extension
2. completes the current turn through the same internal completion path used for a real pi `agent_end`
3. ignores any later duplicate real `agent_end` because the turn is already settled

This exists because extension commands such as `/print-tools` can bypass normal agent lifecycle events,
so they are not guaranteed to produce a real pi `agent_end`.

### 7. Turn ends

Normally, pi finishes the current turn and emits `agent_end`. The shim then:
- keeps the pi process and socket alive for the next turn in the same thread
- sends `turn/completed` to Symphony

If the turn fails, the shim sends `turn/failed`.

### 8. Thread ends

When Symphony ends the overall session (for example by closing stdin / terminating the app-server
process), the shim:
- terminates pi
- closes and cleans up the socket
- releases all per-thread state

---

## Socket Message Reference

All socket messages are newline-delimited JSON.

| Direction       | Type         | Fields                  | Description                      |
|----------------|--------------|-------------------------|----------------------------------|
| shim → ext     | `ping`       | `id`                    | liveness check                   |
| ext → shim     | `pong`       | `id`                    | handshake reply                  |
| shim → ext     | `tools`      | `tools:[...]`           | forward Symphony dynamic tools   |
| ext → shim     | `tool_call`  | `id, name, args`        | extension-originated tool call   |
| shim → ext     | `tool_reply` | `id, result`            | tool result from Symphony        |

The `id` field on `tool_call` / `tool_reply` is a UUID generated by the extension,
used to match replies to outstanding requests.

---

## Invariants

- **Symphony protocol is never violated.** The shim always sends valid Codex responses.
- **Tool calls round-trip through Symphony.** The shim forwards dynamic tool calls to Symphony and waits for the real result.
- **Ping/pong before tools.** The shim never sends `tools` until it has received a `pong` on that connection.
- **One thread, many turns.** Setup is done once at `thread/start`, then the same live session handles multiple `turn/start` requests.
- **UUID matching.** Every `tool_call` carries a UUID. The shim only routes a `tool_reply` if the UUID matches an outstanding request.
- **Synthetic completion is test-only.** `result.shim.cmd == "synthetic:agent_end"` is a shim-private control path used only for the `push_to_symphony` test mechanism.

---

## File Locations

| File                                              | Role                                              |
|---------------------------------------------------|---------------------------------------------------|
| `pi-codex-shim.ts`                                | The shim (Codex ↔ socket bridge)                  |
| `.pi/extensions/shim-extention.ts`                | Generic pi extension (socket client + tool proxy) |
| `elixir/test/support/pi_extensions/push_to_symphony.ts` | Test-only pi extension for `push_to_symphony`      |
| `docs/pi-shim-test-extension.md`                  | Test-only synthetic completion/control contract   |
