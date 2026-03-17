#!/usr/bin/env node
/**
 * symphony-session-live.mjs
 *
 * Live viewer for a Symphony-managed pi session.
 *
 * Generates the pi export HTML, patches it for live updates, and serves it
 * locally. The in-page SSE client connects directly to Symphony's
 * /api/v1/:issue/stream endpoint to receive pi session entries as they arrive.
 *
 * Usage:
 *   node tools/symphony-session-live.mjs <symphonyBase> <issueIdentifier> [port]
 *   node tools/symphony-session-live.mjs http://localhost:4000 ENG-123 7700
 *
 * The Symphony server must be reachable from the browser (CORS or same host).
 */

import { createServer } from 'http';
import { writeFileSync, readFileSync, mkdtempSync } from 'fs';
import { execSync } from 'child_process';
import { tmpdir } from 'os';
import { join } from 'path';

const [,, symphonyBase, issueId, rawPort] = process.argv;
const port = parseInt(rawPort || '7700', 10);

if (!symphonyBase || !issueId) {
  console.error('Usage: node tools/symphony-session-live.mjs <symphonyBase> <issueIdentifier> [port]');
  console.error('Example: node tools/symphony-session-live.mjs http://localhost:4000 ENG-123 7700');
  process.exit(1);
}

const sseUrl = `${symphonyBase}/api/v1/${issueId}/stream`;

// ── Generate initial HTML via `pi --export` ──────────────────────────────────
// We need a minimal session JSONL stub so pi can produce the template HTML.
const tmpDir  = mkdtempSync(join(tmpdir(), 'symphony-live-'));
const stubJsonl = join(tmpDir, 'stub.jsonl');
const tmpHtml   = join(tmpDir, 'session.html');

writeFileSync(
  stubJsonl,
  JSON.stringify({ type: 'session', version: 3, id: 'live-stub', timestamp: new Date().toISOString(), cwd: '/' }) + '\n'
);

console.log('Generating viewer HTML via pi --export …');
try {
  execSync(`pi --export "${stubJsonl}" "${tmpHtml}"`, { stdio: 'inherit' });
} catch (e) {
  console.error('Failed to generate export HTML. Is `pi` in your PATH?', e.message);
  process.exit(1);
}

let html = readFileSync(tmpHtml, 'utf8');

// ── Patch 1: expose IIFE internals as window globals ─────────────────────────
const IIFE_END = '    })();';
const exposeBlock = `
      // ── Live mode: expose session state as globals ──────────────────────
      window.__piEntries      = entries;
      window.__piById         = byId;
      window.__piToolCallMap  = toolCallMap;
      window.__piLabelMap     = labelMap;
      window.__piNavigateTo   = navigateTo;
      window.__piDefaultLeaf  = leafId;
      window.__piInvalidateTree = function() { treeNodeMap = null; };
`;

const iifePos = html.lastIndexOf(IIFE_END);
if (iifePos === -1) {
  console.error('Could not find IIFE closing in generated HTML — pi template may have changed.');
  process.exit(1);
}
html = html.slice(0, iifePos) + exposeBlock + html.slice(iifePos);

// ── Patch 2: inject SSE client before </body> ─────────────────────────────
const encodedSseUrl = JSON.stringify(sseUrl);
const encodedIssue  = JSON.stringify(issueId);

const liveClient = `
<div id="pi-live-indicator" style="
  position: fixed; bottom: 12px; right: 12px; z-index: 9999;
  background: rgba(30,30,30,0.85); color: #4ade80;
  padding: 4px 10px; border-radius: 6px; font-size: 12px;
  font-family: monospace; pointer-events: none;
  border: 1px solid rgba(74,222,128,0.3);
">● live</div>
<script>
(function () {
  var SSE_URL = ${encodedSseUrl};
  var ISSUE   = ${encodedIssue};
  var indicator = document.getElementById('pi-live-indicator');

  function setStatus(text, color) {
    if (indicator) {
      indicator.textContent = text;
      indicator.style.color = color;
    }
  }

  function applyEntry(entry) {
    if (!entry || !entry.id) return;

    window.__piEntries.push(entry);
    window.__piById.set(entry.id, entry);

    if (entry.type === 'message' && entry.message && entry.message.role === 'assistant') {
      var content = entry.message.content;
      if (Array.isArray(content)) {
        for (var i = 0; i < content.length; i++) {
          var block = content[i];
          if (block.type === 'toolCall') {
            window.__piToolCallMap.set(block.id, { name: block.name, arguments: block.arguments });
          }
        }
      }
    }

    if (entry.type === 'label' && entry.targetId && entry.label) {
      window.__piLabelMap.set(entry.targetId, entry.label);
    }

    if (window.__piInvalidateTree) window.__piInvalidateTree();
    window.__piNavigateTo(entry.id, 'bottom');
  }

  function connect() {
    var es = new EventSource(SSE_URL);

    es.onopen = function () { setStatus('● live', '#4ade80'); };

    es.onmessage = function (e) {
      try {
        // Symphony envelope: {event:"frontend_stream", payload:{method:"frontend-stream",params:<pi_entry>}, ...}
        var envelope = JSON.parse(e.data);
        if (envelope.event !== 'frontend_stream') return;
        var entry = envelope.payload && envelope.payload.params;
        applyEntry(entry);
      } catch (err) {
        console.error('[symphony-live] parse error:', err, e.data);
      }
    };

    es.onerror = function () {
      es.close();
      setStatus('○ reconnecting…', '#facc15');
      setTimeout(connect, 3000);
    };
  }

  setTimeout(connect, 200);
})();
</script>
`;

html = html.replace('</body>', liveClient + '\n</body>');

// ── HTTP server ───────────────────────────────────────────────────────────────
const server = createServer((_req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`\n  Symphony session live viewer`);
  console.log(`  URL     : http://localhost:${port}`);
  console.log(`  Issue   : ${issueId}`);
  console.log(`  SSE     : ${sseUrl}`);
  console.log(`\n  Press Ctrl+C to stop.\n`);
});
