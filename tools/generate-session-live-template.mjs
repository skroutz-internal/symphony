#!/usr/bin/env node
/**
 * generate-session-live-template.mjs
 *
 * Pre-generates the patched pi export HTML template for Symphony's live
 * session viewer. Run this when the pi version changes.
 *
 * Output: elixir/priv/static/session-live-template.html
 *
 * The template contains a {{SSE_URL}} placeholder that the Elixir controller
 * substitutes with the per-issue SSE endpoint at request time.
 *
 * Usage:
 *   node tools/generate-session-live-template.mjs
 */

import { writeFileSync, readFileSync, mkdtempSync } from 'fs';
import { execSync } from 'child_process';
import { tmpdir } from 'os';
import { join, resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outPath = join(repoRoot, 'elixir', 'priv', 'static', 'session-live-template.html');

const SSE_URL_PLACEHOLDER = '{{SSE_URL}}';

// ── Generate base HTML via `pi --export` ─────────────────────────────────────
const tmpDir = mkdtempSync(join(tmpdir(), 'symphony-live-gen-'));
const stubJsonl = join(tmpDir, 'stub.jsonl');
const tmpHtml = join(tmpDir, 'session.html');

writeFileSync(
  stubJsonl,
  JSON.stringify({ type: 'session', version: 3, id: 'live-stub', timestamp: new Date().toISOString(), cwd: '/' }) + '\n'
);

console.log('Running pi --export …');
try {
  execSync(`pi --export "${stubJsonl}" "${tmpHtml}"`, { stdio: 'inherit' });
} catch (e) {
  console.error('Failed: is `pi` in your PATH?', e.message);
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
      window.__piInvalidateTree = function() { treeNodeMap = null; treeRendered = false; };
`;

const iifePos = html.lastIndexOf(IIFE_END);
if (iifePos === -1) {
  console.error('Could not find IIFE closing — pi template may have changed.');
  process.exit(1);
}
html = html.slice(0, iifePos) + exposeBlock + html.slice(iifePos);

// ── Patch 2: inject SSE client before </body> (uses {{SSE_URL}} placeholder) ─
const sseClient = `
<div id="pi-live-indicator" style="
  position: fixed; bottom: 12px; right: 12px; z-index: 9999;
  background: rgba(30,30,30,0.85); color: #4ade80;
  padding: 4px 10px; border-radius: 6px; font-size: 12px;
  font-family: monospace; pointer-events: none;
  border: 1px solid rgba(74,222,128,0.3);
">● live</div>
<script>
(function () {
  var SSE_URL = ${JSON.stringify(SSE_URL_PLACEHOLDER)};
  var indicator = document.getElementById('pi-live-indicator');
  var sessionCount = 0;
  var entryCount = 0;

  function setStatus(text, color) {
    if (indicator) {
      indicator.textContent = text;
      indicator.style.color = color;
    }
  }

  var lastEntryId = null;

  function pushEntry(entry) {
    window.__piEntries.push(entry);
    window.__piById.set(entry.id, entry);
    lastEntryId = entry.id;
    if (window.__piInvalidateTree) window.__piInvalidateTree();
    window.__piNavigateTo(entry.id, 'bottom');
  }

  function applyEntry(entry) {
    if (!entry || !entry.id) return;
    // Deduplicate: buffer replay may send events already seen live
    if (window.__piById.has(entry.id)) return;

    entryCount++;
    setStatus('● ' + entryCount + ' entries · s' + (sessionCount || 1), '#4ade80');

    if (entry.type === 'session') {
      sessionCount++;
      if (sessionCount > 1) {
        // Inject a synthetic divider as the last node of the previous session.
        // The new session root hangs off it, making both sessions a single continuous tree.
        var dividerId = 'session-break-' + Date.now();
        var divider = {
          type: 'message',
          id: dividerId,
          parentId: lastEntryId,
          timestamp: new Date().toISOString(),
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: '---\\n\\n**↩ New session started** — previous conversation history was not included.\\n\\n---' }],
          },
        };
        pushEntry(divider);

        // Attach the new session root to the divider
        entry.parentId = dividerId;
      }
    }

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

    pushEntry(entry);
  }

  function connect() {
    var es = new EventSource(SSE_URL);

    es.onopen = function () { setStatus('● live', '#4ade80'); };

    es.onmessage = function (e) {
      try {
        // Symphony envelope: {"event":"frontend_stream","payload":{"method":"frontend-stream","params":<pi_entry>},...}
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

html = html.replace('</body>', sseClient + '\n</body>');

// ── Write output ──────────────────────────────────────────────────────────────
writeFileSync(outPath, html, 'utf8');
console.log(`Written: ${outPath}`);
console.log('Regenerate this file when the pi version changes.');
