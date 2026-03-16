#!/usr/bin/env node
/**
 * pi-codex-shim: bridges Symphony's Codex app-server JSON-RPC protocol to `pi --mode rpc`.
 *
 * Symphony sends (over stdin):
 *   1. {"method":"initialize","id":1,"params":{...}}
 *   2. {"method":"initialized","params":{}}          (notification, no response)
 *   3. {"method":"thread/start","id":2,"params":{"dynamicTools":[...],"cwd":"...",...}}
 *   4. {"method":"turn/start","id":3,"params":{"input":[{"text":"..."}],"cwd":"...",...}}
 *   5. {"id":"<uuid>","result":{...}}                (reply to item/tool/call we sent)
 *
 * The shim:
 *   - ACKs initialize / thread/start
 *   - On thread/start: creates a long-lived Unix socket, spawns pi --mode rpc,
 *     handles the extension connection (ping/pong + tools forwarding)
 *   - On turn/start: sends {"type":"prompt","message":"..."} to pi stdin,
 *     waits for agent_end, then sends turn/completed (or turn/failed)
 *   - Auto-approves extension_ui_request dialogs from pi
 *   - Proxies tool calls: extension sends tool_call on socket →
 *     shim forwards as item/tool/call to Symphony →
 *     Symphony replies → shim sends tool_reply back to extension
 *   - Saves the pi session outside the repo/worktree under
 *     <logs-root>/<workspace-name>/pi-session-<timestamp>.jsonl
 *     (via pi's --session flag — pi writes the full conversation JSONL natively)
 *   - Saves a shim diagnostics log alongside it as
 *     <logs-root>/<workspace-name>/shim-<timestamp>.jsonl
 *
 * Environment variables:
 *   PI_BIN            — path to the pi binary (default: "pi")
 *   PI_SHIM_LOG       — log file path (default: /tmp/pi-codex-shim.log)
 */

"use strict";

const { spawn } = require("child_process");
const readline = require("readline");
const fs = require("fs");
const path = require("path");
const net = require("net");
const os = require("os");
const crypto = require("crypto");

const LOG_FILE = process.env.PI_SHIM_LOG || "/tmp/pi-codex-shim.log";
const logStream = fs.createWriteStream(LOG_FILE, { flags: "a" });

function nowTs() {
  return new Date().toISOString();
}

function log(entry) {
  if (typeof entry === "string") {
    logStream.write("[pi-codex-shim] " + entry + "\n");
    return;
  }

  const line = JSON.stringify(entry);
  logStream.write("[pi-codex-shim] " + line + "\n");
  if (shimLog) {
    shimLog.write(JSON.stringify({ timestamp: nowTs(), ...entry }) + "\n");
  }
}

function send(obj) {
  log({ _shim: "symphony_rpc", direction: "to_symphony", event: obj });
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function sendToPi(obj) {
  if (!piProcess || !piProcess.stdin.writable) {
    throw new Error("pi stdin is not writable");
  }

  log({ _shim: "pi_rpc", direction: "to_pi", event: obj });
  piProcess.stdin.write(JSON.stringify(obj) + "\n");
}

// ── module-level state ─────────────────────────────────────────────────────

// Dynamic tools received from Symphony in thread/start
let dynamicTools = [];

// Workspace cwd received from thread/start — used for session file path
let threadCwd = null;

// Pending tool calls: id → { resolve, reject }
// When Symphony replies to an item/tool/call, we look up by id and resolve.
const pendingToolCalls = new Map();

// Long-lived pi process (spawned once on thread/start)
let piProcess = null;

// Resolver for the currently active turn (set by runTurn, resolved on agent_end)
let currentTurnResolve = null;
let currentTurnReject = null;

function completeCurrentTurn(source) {
  log(`${source} — turn complete`);
  log({ _shim: "turn_complete", source });
  if (currentTurnResolve) {
    currentTurnResolve();
    currentTurnResolve = null;
    currentTurnReject = null;
  }
}

function rejectCurrentTurn(reason) {
  if (currentTurnReject) {
    currentTurnReject(new Error(reason));
    currentTurnResolve = null;
    currentTurnReject = null;
  }
}

// Socket cleanup function (called on process exit)
let socketClose = null;

// Shim diagnostics log for the current session
let shimLog = null;

// Human-readable activity log for the current session
let activityLog = null;

function createControlSocket() {
  const socketPath = path.join(os.tmpdir(), `pi-shim-${process.pid}-${Date.now()}.sock`);
  try { fs.unlinkSync(socketPath); } catch (_) {}

  const server = net.createServer((conn) => {
    log("control socket: extension connected");
    handleExtensionConnection(conn);
  });

  server.on("error", (err) => log(`control socket error: ${err.message}`));
  server.listen(socketPath, () => log(`control socket listening: ${socketPath}`));

  const close = () => new Promise((resolve) => {
    server.close(() => {
      try { fs.unlinkSync(socketPath); } catch (_) {}
      resolve();
    });
  });

  return { socketPath, close };
}

async function handleExtensionConnection(conn) {
  let buf = "";
  const queue = [];
  const waiters = [];
  let closed = false;

  conn.on("data", (chunk) => {
    buf += chunk.toString();
    const lines = buf.split("\n");
    buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (waiters.length > 0) waiters.shift()(msg);
      else queue.push(msg);
    }
  });

  const drain = () => { closed = true; while (waiters.length) waiters.shift()(null); };
  conn.on("end", drain);
  conn.on("error", (err) => { log(`extension conn error: ${err.message}`); drain(); });

  const recv = () => new Promise((resolve) => {
    if (queue.length > 0) resolve(queue.shift());
    else if (closed) resolve(null);
    else waiters.push(resolve);
  });

  const connSend = (obj) => {
    try { conn.write(JSON.stringify(obj) + "\n"); } catch (e) { log(`connSend error: ${e.message}`); }
  };

  // ── ping / pong handshake ──────────────────────────────────────────────
  const pingId = crypto.randomUUID();
  connSend({ type: "ping", id: pingId });
  const pong = await recv();
  if (!pong || pong.type !== "pong" || pong.id !== pingId) {
    log(`ping/pong failed: ${JSON.stringify(pong)}`);
    conn.end();
    return;
  }
  log("ping/pong ok");

  // ── send tools ────────────────────────────────────────────────────────
  const allTools = dynamicTools;

  connSend({ type: "tools", tools: allTools });
  log(`sent ${allTools.length} tools to extension`);

  // ── handle tool calls from the extension ─────────────────────────────
  while (true) {
    const msg = await recv();
    if (!msg) break; // connection closed

    if (msg.type === "tool_call") {
      const { id, name, args } = msg;
      log(`tool_call from extension: ${name} id=${id}`);

      // Forward to Symphony as Codex item/tool/call
      send({ id, method: "item/tool/call", params: { name, arguments: args } });

      // Register pending — will be resolved when Symphony replies on stdin
      const result = await new Promise((resolve, reject) => {
        pendingToolCalls.set(id, { resolve, reject });
        setTimeout(() => {
          if (pendingToolCalls.has(id)) {
            pendingToolCalls.delete(id);
            reject(new Error(`tool call timeout: ${name} id=${id}`));
          }
        }, 30_000);
      }).catch((err) => {
        log(`tool_call error: ${err.message}`);
        return { success: false, error: err.message };
      });

      connSend({ type: "tool_reply", id, result });

      if (name === "push_to_symphony" && result?.shim?.cmd === "synthetic:agent_end") {
        completeCurrentTurn("shim synthetic:agent_end");
      }
    } else {
      log(`unexpected socket message: ${JSON.stringify(msg)}`);
    }
  }

  log("extension disconnected");
}

// ── shim event log ─────────────────────────────────────────────────────────

function logsDirForWorkspace(cwd) {
  const workspaceName = path.basename(path.resolve(cwd));
  const root =
    process.env.SYMPHONY_AGENT_LOGS_ROOT ||
    path.join(process.env.SYMPHONY_WORKSPACES_ROOT || path.dirname(path.resolve(cwd)), "_logs");
  const logsDir = path.join(root, workspaceName);
  fs.mkdirSync(logsDir, { recursive: true });
  return logsDir;
}

function openShimLog(cwd) {
  const logsDir = logsDirForWorkspace(cwd);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const logFile = path.join(logsDir, `shim-${timestamp}.jsonl`);
  const stream = fs.createWriteStream(logFile, { flags: "a" });
  log(`shim event log: ${logFile}`);
  return stream;
}

function openActivityLog(cwd) {
  const logsDir = logsDirForWorkspace(cwd);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const logFile = path.join(logsDir, `activity-${timestamp}.log`);
  const stream = fs.createWriteStream(logFile, { flags: "a" });
  log(`activity log: ${logFile}`);
  return stream;
}

function activity(line) {
  if (activityLog) activityLog.write("• " + line + "\n");
}

const ACTIVITY_TRUNCATE = 300;

function trunc(s) {
  const flat = String(s).replace(/\s+/g, " ");
  return flat.length > ACTIVITY_TRUNCATE ? flat.slice(0, ACTIVITY_TRUNCATE) + "…" : flat;
}

function formatToolActivity(toolName, args) {
  if (toolName === "bash") {
    return `[bash: ${trunc(args.command || "")}]`;
  }
  if (toolName === "read") {
    const p = args.path || "";
    const start = args.offset || 1;
    const end = args.limit ? start + args.limit - 1 : "?";
    const range = (args.offset || args.limit) ? `:${start}-${end}` : "";
    return `[read: ${p}${range}]`;
  }
  return `[${toolName}: ${trunc(JSON.stringify(args))}]`;
}

function createAgentIdentity() {
  return `symphony(${crypto.randomBytes(4).toString("hex")})`;
}

function piSessionPath(cwd) {
  const logsDir = logsDirForWorkspace(cwd);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  return path.join(logsDir, `pi-session-${timestamp}.jsonl`);
}

function parseAgentEnvValue(rawValue) {
  const trimmed = rawValue.trim();
  if (trimmed.length >= 2) {
    const first = trimmed[0];
    const last = trimmed[trimmed.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed;
}

function loadEnvFile(envPath) {
  if (!fs.existsSync(envPath)) {
    return {};
  }

  const content = fs.readFileSync(envPath, "utf8");
  const env = {};

  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const match = trimmed.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;

    const [, key, rawValue] = match;
    env[key] = parseAgentEnvValue(rawValue);
  }

  log({ _shim: "env_file_loaded", path: envPath, keys: Object.keys(env).sort() });
  return env;
}

function loadAgentEnv(cwd) {
  return loadEnvFile(path.join(cwd, ".agent-env"));
}

function loadShimEnv(cwd) {
  return loadEnvFile(path.join(cwd, ".shim-env"));
}

// ── pi RPC event handler ───────────────────────────────────────────────────

function shouldLogPiEvent(msg) {
  if (!msg || typeof msg !== "object") return true;

  if (typeof msg.type === "string" && msg.type.endsWith("_delta")) {
    return false;
  }

  if (msg.type === "message_update") {
    const updateType = msg.assistantMessageEvent && msg.assistantMessageEvent.type;
    if (typeof updateType === "string") {
      if (updateType.endsWith("_delta")) {
        return false;
      }
      if (updateType === "toolcall_start" || updateType === "toolcall_end" || updateType === "text_start" || updateType === "text_end") {
        return false;
      }
    }
  }

  if (msg.type === "message_start" || msg.type === "message_end") {
    return false;
  }

  if (msg.type === "turn_start" || msg.type === "turn_end") {
    return false;
  }

  if (msg.type === "tool_execution_update") {
    return false;
  }

  return true;
}

function handlePiLine(line) {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch {
    log("pi non-json: " + line.slice(0, 200));
    log({ _shim: "non_json", raw: line });
    return;
  }

  if (shouldLogPiEvent(msg)) {
    log({ _shim: "pi_rpc", direction: "from_pi", event: msg });
  }

  const t = msg.type;

  if (t === "tool_execution_start") {
    activity(formatToolActivity(msg.toolName, msg.args || {}));
  }

  if (t === "tool_execution_end") {
    const result = msg.result;
    if (result) {
      const output = Array.isArray(result.content)
        ? result.content.filter((c) => c.type === "text").map((c) => c.text).join(" ")
        : String(result);
      if (output.trim()) activity(`  result: ${trunc(output)}`);
    }
  }

  if (t === "message_update") {
    const ae = msg.assistantMessageEvent || {};
    if (ae.type === "thinking_end" && ae.content && ae.content.trim()) {
      activity(`  think: ${ae.content.trim()}`);
    }
  }

  if (t === "message_end" && msg.message && msg.message.role === "assistant") {
    const text = (msg.message.content || [])
      .filter((c) => c.type === "text")
      .map((c) => c.text)
      .join(" ");
    if (text.trim()) activity(`assistant: ${trunc(text)}`);
  }

  if (t === "agent_end") {
    completeCurrentTurn("pi agent_end");
    return;
  }

  if (t === "extension_ui_request") {
    handleUiRequest(msg);
    return;
  }

  if (t === "auto_retry_end" && msg.success === false) {
    log(`pi auto_retry failed: ${msg.finalError}`);
    rejectCurrentTurn(`pi auto_retry exhausted: ${msg.finalError}`);
    return;
  }

  if (t === "response") {
    log(`pi rpc response: command=${msg.command} success=${msg.success}`);
    return;
  }

  // Other events (turn_start, turn_end, message_update, etc.) — log only
  if (t && t !== "message_update") log(`pi event: ${t}`);
}

function handleUiRequest(msg) {
  // Auto-approve all dialog requests from extensions
  const { id, method } = msg;
  log(`auto-approving extension_ui_request: method=${method} id=${id}`);

  let response;
  if (method === "confirm") {
    response = { type: "extension_ui_response", id, confirmed: true };
  } else if (method === "select") {
    const value = Array.isArray(msg.options) && msg.options.length > 0 ? msg.options[0] : null;
    response = { type: "extension_ui_response", id, value };
  } else if (method === "input" || method === "editor") {
    response = { type: "extension_ui_response", id, value: "" };
  } else {
    // fire-and-forget (notify, setStatus, setWidget, setTitle) — no response needed
    return;
  }

  if (piProcess && piProcess.stdin.writable) {
    sendToPi(response);
  }
}

// ── pi process lifecycle ───────────────────────────────────────────────────

function startPiProcess(cwd, sessionFile, socketPath) {
  const piPath = process.env.PI_BIN || "pi";
  const extensionPath = path.join(__dirname, ".pi", "extensions", "shim-extention.ts");
  const hasExtension = fs.existsSync(extensionPath);
  const agentEnv = loadAgentEnv(cwd);
  const shimEnv = loadShimEnv(cwd);
  const agentIdentity = createAgentIdentity();

  const args = ["--mode", "rpc", "--session", sessionFile, "--no-skills", "--skill", path.join(__dirname, "pi-skills/land"), "--no-extensions"];
  if (shimEnv.MODEL) args.splice(2, 0, "--model", shimEnv.MODEL);
  if (hasExtension) {
    args.push("-e", extensionPath);
  } else {
    log(`extension not found: ${extensionPath}`);
  }

  const spawnCommand = `${piPath} ${args.join(" ")}`;
  log(`spawning pi: ${spawnCommand} cwd=${cwd}`);

  piProcess = spawn(piPath, args, {
    cwd,
    env: {
      ...process.env,
      ...agentEnv,
      ...(shimEnv.SYMPHONY_AGENT_LOGS_ROOT ? { SYMPHONY_AGENT_LOGS_ROOT: shimEnv.SYMPHONY_AGENT_LOGS_ROOT } : {}),
      PI_SHIM_SOCKET: socketPath,
      SYMPHONY_AGENT_IDENTITY: agentIdentity,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });

  log({ _shim: "pi_spawned", pid: piProcess.pid, command: spawnCommand, cwd, agentIdentity });

  piProcess.stderr.on("data", (d) => {
    const text = d.toString().trim();
    log("pi stderr: " + text);
    log({ _shim: "stderr", text });
  });

  const piRl = readline.createInterface({ input: piProcess.stdout });
  piRl.on("line", handlePiLine);

  piProcess.on("exit", (code, signal) => {
    log(`pi exit event code=${code} signal=${signal}`);
    log({ _shim: "pi_exit_event", code, signal });
  });

  piProcess.on("close", (code, signal) => {
    log(`pi close event code=${code} signal=${signal}`);
    log({ _shim: "pi_exit", code, signal });
    if (currentTurnReject) {
      const detail = signal ? `signal ${signal}` : `code ${code}`;
      rejectCurrentTurn(`pi exited mid-turn with ${detail}`);
    }
  });

  piProcess.on("error", (err) => {
    log(`pi spawn error: ${err.message}`);
    log({ _shim: "pi_error", message: err.message });
    if (currentTurnReject) {
      rejectCurrentTurn(err.message);
    }
  });
}

// ── send a turn prompt to pi ───────────────────────────────────────────────

function runTurn(prompt) {
  return new Promise((resolve, reject) => {
    if (!piProcess || piProcess.killed) {
      return reject(new Error("pi process is not running"));
    }
    currentTurnResolve = resolve;
    currentTurnReject = reject;
    log({ _shim: "prompt_sent", message: prompt });
    activity(`user: ${trunc(prompt)}`);
    sendToPi({ type: "prompt", message: prompt });
  });
}

// ── main protocol loop ─────────────────────────────────────────────────────

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", async (line) => {
  if (!line.trim()) return;

  let msg;
  try { msg = JSON.parse(line); } catch {
    log("received non-json: " + line.slice(0, 200));
    log({ _shim: "stdin_non_json", raw: line });
    return;
  }

  log({ _shim: "symphony_rpc", direction: "from_symphony", event: msg });

  const method = msg.method;
  const id = msg.id;

  // ── Symphony replies to item/tool/call we sent ───────────────────────
  if (!method && id && pendingToolCalls.has(id)) {
    const { resolve } = pendingToolCalls.get(id);
    pendingToolCalls.delete(id);
    log(`tool_reply from Symphony: id=${id}`);
    resolve(msg.result);
    return;
  }

  if (method === "initialize") {
    log("initialize");
    send({ id, result: {} });
    return;
  }

  if (method === "initialized") {
    log("initialized (notification)");
    return;
  }

  if (method === "thread/start") {
    dynamicTools = (msg.params || {}).dynamicTools || [];
    threadCwd = (msg.params || {}).cwd || null;
    log(`thread/start — ${dynamicTools.length} dynamic tools, cwd=${threadCwd}`);

    const cwd = threadCwd || process.cwd();
    // Apply shim env early so SYMPHONY_AGENT_LOGS_ROOT is visible to log path helpers
    const shimEnvEarly = loadShimEnv(cwd);
    if (shimEnvEarly.SYMPHONY_AGENT_LOGS_ROOT) {
      process.env.SYMPHONY_AGENT_LOGS_ROOT = shimEnvEarly.SYMPHONY_AGENT_LOGS_ROOT;
    }
    shimLog = openShimLog(cwd);
    activityLog = openActivityLog(cwd);
    const sessionFile = piSessionPath(cwd);

    const { socketPath, close } = createControlSocket();
    socketClose = close;

    startPiProcess(cwd, sessionFile, socketPath);

    send({ id, result: { thread: { id: "pi-thread-1" } } });
    return;
  }

  if (method === "turn/start") {
    const params = msg.params || {};
    const cwd = params.cwd || threadCwd || process.cwd();
    const inputItems = params.input || [];
    const prompt = inputItems
      .filter((i) => i.type === "text")
      .map((i) => i.text)
      .join("\n");

    log(`turn/start cwd=${cwd} prompt_len=${prompt.length}`);

    // ACK the turn immediately
    send({ id, result: { turn: { id: "pi-turn-1" } } });

    try {
      await runTurn(prompt);
      send({ method: "turn/completed" });
    } catch (err) {
      log("turn failed: " + err.message);
      send({ method: "turn/failed", params: { reason: err.message } });
    }
    return;
  }

  // Command execution approval → auto-approve
  if (method === "item/commandExecution/requestApproval") {
    log(`auto-approving command: ${(msg.params || {}).command}`);
    send({ id, result: { decision: "acceptForSession" } });
    return;
  }

  // Tool user-input request → generic non-interactive answer
  if (method === "item/tool/requestUserInput") {
    const questions = (msg.params || {}).questions || [];
    const answers = {};
    for (const q of questions) {
      const opts = q.options;
      if (Array.isArray(opts) && opts.length > 0) {
        const approveOpt = opts.find((o) => o.label === "Approve this Session");
        answers[q.id] = { answers: [(approveOpt || opts[0]).label] };
      } else {
        answers[q.id] = {
          answers: ["This is a non-interactive session. Operator input is unavailable."],
        };
      }
    }
    log(`answering tool user-input: ${Object.keys(answers).join(", ")}`);
    send({ id, result: { answers } });
    return;
  }

  if (method === "item/tool/call") {
    const toolName = (msg.params || {}).name || "unknown";
    log(`unexpected direct tool call: ${toolName}`);
    send({
      id,
      result: {
        success: false,
        contentItems: [{ type: "inputText", text: `Unsupported dynamic tool: ${toolName}` }],
      },
    });
    return;
  }

  log(`unhandled method: ${method}`);
});

process.stdin.on("end", () => {
  log("stdin end from Symphony");
  log({ _shim: "stdin_end" });
});

process.stdin.on("close", () => {
  log("stdin close from Symphony");
  log({ _shim: "stdin_close" });
});

process.stdin.on("error", (err) => {
  log(`stdin error from Symphony: ${err.message}`);
  log({ _shim: "stdin_error", message: err.message });
});

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    log(`shim received ${sig}`);
    log({ _shim: "signal", signal: sig });
  });
}

process.on("beforeExit", (_code) => {
  // Do not write to streams here. beforeExit fires when the event loop is empty,
  // and asynchronous writes can keep re-scheduling work, causing a hot spin.
});

process.on("exit", (code) => {
  log(`shim exit code=${code}`);
  log({ _shim: "process_exit", code });
});

rl.on("close", () => {
  log("readline close on shim stdin — killing pi");
  log({ _shim: "readline_close" });
  if (piProcess && !piProcess.killed) {
    log("sending SIGTERM to pi because shim stdin closed");
    log({ _shim: "kill_pi", reason: "shim stdin closed", signal: "SIGTERM" });
    piProcess.kill();
  }
  if (socketClose) socketClose();
});
