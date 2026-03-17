#!/usr/bin/env node
/**
 * test-session-live.mjs
 *
 * Visual test for the Symphony session live viewer.
 *
 * Serves the pre-generated session-live-template.html locally and streams
 * synthetic pi session entries wrapped in Symphony's SSE envelope format,
 * one per second. Streams two sessions with a pause between them to test
 * the session-change banner. No Symphony or pi runtime needed.
 *
 * Usage:
 *   node tools/test-session-live.mjs [port]
 *   node tools/test-session-live.mjs 7700
 */

import { createServer } from 'http';
import { readFileSync } from 'fs';
import { resolve, dirname, join } from 'path';
import { fileURLToPath } from 'url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const templatePath = join(repoRoot, 'elixir', 'priv', 'static', 'session-live-template.html');
const port = parseInt(process.argv[2] || '7700', 10);

const SSE_URL = `http://localhost:${port}/stream`;
const html = readFileSync(templatePath, 'utf8').replace('{{SSE_URL}}', SSE_URL);

// ── Synthetic pi session entries ─────────────────────────────────────────────

function ts(offsetMs = 0) {
  return new Date(Date.now() + offsetMs).toISOString();
}

function makeSession(label) {
  const sid = 'test-session-' + Math.random().toString(36).slice(2, 8);
  const user   = sid + '-user';
  const asst1  = sid + '-asst-1';
  const asst2  = sid + '-asst-2';
  const tcall  = sid + '-tool-call';
  const tresult = sid + '-tool-result';

  return [
    { type: 'session', version: 3, id: sid, timestamp: ts(), cwd: repoRoot },
    {
      type: 'message', id: user, parentId: sid, timestamp: ts(500),
      message: { role: 'user', content: [{ type: 'text', text: `[${label}] Implement the feature from the issue description.` }] },
    },
    {
      type: 'message', id: asst1, parentId: user, timestamp: ts(1000),
      message: {
        role: 'assistant',
        content: [
          { type: 'text', text: "I'll start by reading the relevant files." },
          { type: 'toolCall', id: tcall, name: 'read', arguments: { path: 'elixir/lib/symphony_elixir_web/router.ex' } },
        ],
      },
    },
    {
      type: 'message', id: tresult, parentId: asst1, timestamp: ts(1500),
      message: {
        role: 'tool',
        content: [{ type: 'toolResult', toolCallId: tcall, content: [{ type: 'text', text: 'defmodule SymphonyElixirWeb.Router do\n  ...\nend' }] }],
      },
    },
    {
      type: 'message', id: asst2, parentId: tresult, timestamp: ts(2000),
      message: {
        role: 'assistant',
        content: [{ type: 'text', text: `[${label}] Router structure looks good. Adding the new route before the catch-all.` }],
      },
    },
  ];
}

// null sentinel = 3-second pause between sessions
const entries = [
  ...makeSession('Session 1'),
  null,
  null,
  null,
  ...makeSession('Session 2'),
];

// ── SSE helpers ───────────────────────────────────────────────────────────────

function toSsePayload(piEntry) {
  const eventData = {
    event: 'frontend_stream',
    payload: { method: 'frontend-stream', params: piEntry },
    raw: JSON.stringify({ method: 'frontend-stream', params: piEntry }),
    timestamp: new Date().toISOString(),
  };
  return `data: ${JSON.stringify(eventData)}\n\n`;
}

function startStream(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*',
  });
  res.write(': connected\n\n');

  let i = 0;
  const interval = setInterval(() => {
    if (i >= entries.length) {
      clearInterval(interval);
      return;
    }
    const entry = entries[i++];
    if (entry !== null) {
      try { res.write(toSsePayload(entry)); } catch { clearInterval(interval); }
    }
    // null = skip tick (pause)
  }, 1000);

  res.on('close', () => clearInterval(interval));
}

// ── HTTP server ───────────────────────────────────────────────────────────────

createServer((req, res) => {
  if (req.url === '/stream') { startStream(res); return; }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}).listen(port, '127.0.0.1', () => {
  console.log(`\n  Symphony session live — visual test`);
  console.log(`  URL  : http://localhost:${port}`);
  console.log(`  2 sessions, 5 entries each, 3-second pause between sessions`);
  console.log(`\n  Press Ctrl+C to stop.\n`);
});
