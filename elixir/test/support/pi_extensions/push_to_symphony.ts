/**
 * Test-only pi extension used by Symphony's shim/app-server integration tests.
 *
 * Purpose:
 * - expose deterministic extension commands inside a real pi session
 * - provide a generic, test-only channel from pi back to Symphony
 * - exercise the same shim tool-call path that normal dynamic tools use,
 *   without depending on LLM behavior
 *
 * Current command:
 * - `/print-tools` collects `pi.getAllTools()` and sends that payload to Symphony
 *   via the registered `push_to_symphony` tool
 *
 * Why this exists:
 * - we want an end-to-end test with actual pi, not a mocked extension registry
 * - we want the shim to remain opaque: from the shim's point of view, this is just
 *   another tool call flowing through the normal shim extension channel
 *
 * Prerequisite:
 * - `PI_SHIM_SOCKET` must be set by the shim and the generic shim extension must be loaded
 *   so the shared shim client exists.
 *
 * Notes:
 * - this is intentionally a test mechanism, not product behavior
 * - `push_to_symphony` is a generic test/control hook to communicate with Symphony
 * - `/print-tools` is only one current use of that channel
 */
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type ShimClient = {
  ready: Promise<any>;
  callTool: (name: string, args: unknown) => Promise<any>;
};

declare global {
  var __PI_SHIM_CLIENT__: ShimClient | undefined;
}

/**
 * Registers `/print-tools`.
 */
export default function printToolsExtension(pi: ExtensionAPI) {
  pi.registerCommand("print-tools", {
    description: "Push all currently registered tools to Symphony",
    handler: async () => {
      const client = globalThis.__PI_SHIM_CLIENT__;
      if (!client) {
        throw new Error("PI shim client is not available");
      }

      await client.ready;

      const tools = pi.getAllTools().map((tool) => ({
        name: tool.name,
        description: tool.description,
      }));

      if (!tools.some((tool) => tool.name === "push_to_symphony")) {
        throw new Error(
          `push_to_symphony tool is not registered in pi. Visible tools: ${tools
            .map((tool) => tool.name)
            .join(", ")}`,
        );
      }

      const payload = { tools };
      const result = await client.callTool("push_to_symphony", payload);
      return JSON.stringify(result, null, 2);
    },
  });
}
