# pi-codex-shim Interaction Diagram

```mermaid
sequenceDiagram
    participant S as Symphony (Elixir)
    participant SH as Shim (pi-codex-shim.ts)
    participant PI as pi --mode rpc
    participant EXT as shim-extention.ts<br/>(generic pi extension)
    participant TST as push_to_symphony.ts<br/>(test extension)
    participant SOCK as Unix Socket<br/>/tmp/pi-shim-*.sock

    %% ── Session setup ────────────────────────────────────────────────
    Note over S,SOCK: Thread start (once per issue / session)
    Note over SH,PI: One long-lived pi process per thread, reused across turns

    S->>SH: initialize {id:1}
    SH->>S: {id:1, result:{}}
    S->>SH: initialized

    S->>SH: thread/start {cwd, dynamicTools:[...]}
    SH->>SOCK: create socket
    SH->>PI: spawn --mode rpc --session <path>
    SH->>S: {id:2, result:{thread:{id:"pi-thread-1"}}}

    PI->>EXT: load extension on session_start
    EXT->>SOCK: connect
    SH->>EXT: ping {id}
    EXT->>SH: pong {id}
    SH->>EXT: tools [{name, description, inputSchema}, ...]
    Note over EXT: registers Symphony dynamic tools via pi.registerTool()

    PI->>TST: load test extension on session_start
    TST->>SOCK: connect
    SH->>TST: ping {id}
    TST->>SH: pong {id}
    SH->>TST: tools [{name, description, inputSchema}, ...]
    Note over TST: keeps socket open for test/control calls

    %% ── Normal dynamic tool turn ────────────────────────────────────
    Note over S,SOCK: Normal turn path

    S->>SH: turn/start {input:[{type:"text",text:"..."}], cwd}
    SH->>S: {id:3, result:{turn:{id:"pi-turn-1"}}}
    SH->>PI: {"type":"prompt","message":"..."}
    PI->>SH: {"type":"response","command":"prompt","success":true}

    PI->>EXT: tool execute() called internally
    EXT->>SOCK: tool_call {id, name, args}
    SH->>S: item/tool/call {id, name, arguments}
    S->>SH: {id, result:{...}}
    SH->>EXT: tool_reply {id, result}
    EXT->>PI: tool execute() returns result

    PI->>SH: agent_end
    SH->>S: turn/completed

    %% ── Test control path ───────────────────────────────────────────
    Note over S,SOCK: Test-only extension-command path

    S->>SH: turn/start {input:[{type:"text",text:"/print-tools"}], cwd}
    SH->>S: {id:4, result:{turn:{id:"pi-turn-1"}}}
    SH->>PI: {"type":"prompt","message":"/print-tools"}
    PI->>SH: {"type":"response","command":"prompt","success":true}

    PI->>TST: run /print-tools command handler
    TST->>SOCK: tool_call {id, name:"push_to_symphony", args:{tools:[...]}}
    SH->>S: item/tool/call {id, name:"push_to_symphony", arguments:{tools:[...]}}
    S->>SH: {id, result:{success:true, shim:{cmd:"synthetic:agent_end"}, ...}}
    SH->>TST: tool_reply {id, result:{...}}
    Note over SH: intercept result.shim.cmd == "synthetic:agent_end"
    SH->>S: turn/completed

    %% ── Approval (auto) ─────────────────────────────────────────────
    Note over S,SOCK: If extension requests user approval

    PI->>SH: extension_ui_request {id, method:"confirm", title:"..."}
    SH->>PI: extension_ui_response {id, confirmed:true}

    %% ── Failure paths ───────────────────────────────────────────────
    Note over S,SOCK: Failure paths

    alt pi exits mid-turn
        PI->>SH: process exit (code ≠ 0)
        SH->>S: turn/failed {reason:"pi exited mid-turn ..."}
    end

    alt auto retry exhausted
        PI->>SH: auto_retry_end {success:false, finalError:"..."}
        SH->>S: turn/failed {reason:"pi auto_retry exhausted"}
    end

    %% ── Thread end ──────────────────────────────────────────────────
    Note over S,SOCK: Thread end

    S->>SH: stdin closed
    SH->>PI: SIGTERM
    SH->>SOCK: close + unlink
```

## Component Roles

| Component | Protocol | Lifetime |
|---|---|---|
| Symphony (Elixir) | Codex JSON-RPC over stdin/stdout | Process |
| Shim | Codex JSON-RPC ↔ pi RPC bridge | Process (= Symphony subprocess) |
| pi | pi RPC (stdin/stdout) | Thread (1 pi per issue) |
| Generic extension | pi extension API + socket client | = pi lifetime |
| Test extension | pi extension API + socket client | = pi lifetime |
| Unix socket | Custom NDJSON protocol | = pi lifetime |

## Message Legend

**Symphony → Shim** (Codex JSON-RPC):
- `initialize`, `initialized`, `thread/start`, `turn/start`
- `{id, result}` — replies to `item/tool/call`

**Shim → Symphony** (Codex JSON-RPC):
- `{id, result}` — ACKs to initialize / thread/start / turn/start
- `item/tool/call {id, name, arguments}` — dynamic tool dispatch
- `turn/completed` / `turn/failed`

**Shim → Pi** (pi RPC, stdin):
- `{"type":"prompt","message":"..."}` — one per turn
- `{"type":"extension_ui_response","id":"...","confirmed":true}` — auto-approval

**Pi → Shim** (pi RPC, stdout):
- `agent_end`, `turn_end`, `message_update`, `extension_ui_request`, `response`, ...

**Shim ↔ Extension** (Unix socket, NDJSON):
- `ping/pong` — handshake (shim initiates)
- `tools [...]` — dynamic tool specs (shim → extension, once per connection)
- `tool_call {id, name, args}` — extension → shim
- `tool_reply {id, result}` — shim → extension
