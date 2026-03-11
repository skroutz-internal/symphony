import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import * as net from "node:net";
import * as crypto from "node:crypto";

type PendingCall = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
};

type ShimClient = {
  ready: Promise<void>;
  callTool: (name: string, args: unknown) => Promise<any>;
};

declare global {
  var __PI_SHIM_CLIENT__: ShimClient | undefined;
}

function createShimClient(socketPath: string): ShimClient {
  const socket = net.createConnection(socketPath);
  let buf = "";
  const queue: any[] = [];
  const waiters: Array<(value: any) => void> = [];
  const pending = new Map<string, PendingCall>();

  socket.on("data", (chunk) => {
    buf += chunk.toString();
    const lines = buf.split("\n");
    buf = lines.pop()!;

    for (const line of lines) {
      if (!line.trim()) continue;

      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }

      if (msg.type === "tool_reply" && pending.has(msg.id)) {
        const call = pending.get(msg.id)!;
        pending.delete(msg.id);
        call.resolve(msg.result);
      } else {
        if (waiters.length > 0) waiters.shift()!(msg);
        else queue.push(msg);
      }
    }
  });

  socket.on("error", (err) => {
    for (const [, call] of pending) call.reject(new Error(err.message));
    pending.clear();
  });

  socket.on("close", () => {
    for (const [, call] of pending) call.reject(new Error("PI_SHIM_SOCKET closed"));
    pending.clear();
  });

  const recv = (): Promise<any> =>
    new Promise((resolve) => {
      if (queue.length > 0) resolve(queue.shift());
      else waiters.push(resolve);
    });

  const connSend = (obj: any) => socket.write(JSON.stringify(obj) + "\n");

  const ready = (async () => {
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });

    const ping = await recv();
    if (!ping || ping.type !== "ping") {
      throw new Error(`expected ping, got ${JSON.stringify(ping)}`);
    }
    connSend({ type: "pong", id: ping.id });

    const toolsMsg = await recv();
    if (!toolsMsg || toolsMsg.type !== "tools") {
      throw new Error(`expected tools, got ${JSON.stringify(toolsMsg)}`);
    }

    return toolsMsg;
  })();

  return {
    ready,
    callTool: async (name: string, args: unknown) => {
      await ready;
      const id = crypto.randomUUID();
      connSend({ type: "tool_call", name, args, id });

      return await new Promise<any>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        setTimeout(() => {
          if (pending.has(id)) {
            pending.delete(id);
            reject(new Error(`tool call timeout: ${name}`));
          }
        }, 30_000);
      });
    },
  };
}

export default function (pi: ExtensionAPI) {
  const socketPath = process.env.PI_SHIM_SOCKET;
  if (!socketPath) return;

  pi.on("session_start", async () => {
    const client = globalThis.__PI_SHIM_CLIENT__ ?? createShimClient(socketPath);
    globalThis.__PI_SHIM_CLIENT__ = client;

    const toolsMsg = await client.ready;

    for (const tool of toolsMsg.tools) {
      pi.registerTool({
        name: tool.name,
        description: tool.description,
        parameters: tool.inputSchema,
        execute: async (args: any) => {
          const result = await client.callTool(tool.name, args);
          return typeof result === "string" ? result : JSON.stringify(result);
        },
      });
    }
  });
}
