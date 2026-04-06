#!/usr/bin/env node
// Tiny proxy: rewrites model name for Copilot CLI → Foundry Local
// Copilot sends "gpt-4.1", Foundry needs "Phi-4-generic-cpu:1"
//
// Usage:
//   node foundry-proxy.cjs [--help]
//
// Environment variables:
//   FOUNDRY_PORT  - Foundry Local API port (auto-detected if not set)
//   PROXY_PORT    - Port this proxy listens on (default: 5272)

const http = require('http');
const { execSync } = require('child_process');

// --- Help ---
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log(`
  foundry-proxy.cjs — Model-name rewrite proxy for Copilot CLI + Foundry Local

  Rewrites the model name in OpenAI-compatible API requests so the Copilot CLI
  (which sends "gpt-4.1") is transparently routed to a Foundry Local model.

  Environment variables:
    FOUNDRY_PORT   Foundry Local API port (auto-detected from 'foundry service status')
    PROXY_PORT     Port this proxy listens on (default: 5272)

  Model map (edit MODEL_MAP in this file to add models):
    gpt-4.1       → Phi-4-generic-cpu:1
    gpt-5-mini    → Phi-3.5-mini-instruct-generic-cpu:1

  Examples:
    node foundry-proxy.cjs
    FOUNDRY_PORT=49296 PROXY_PORT=5272 node foundry-proxy.cjs
  `);
  process.exit(0);
}

// --- Auto-detect Foundry port ---
function detectFoundryPort() {
  try {
    const output = execSync('foundry service status', { encoding: 'utf8', timeout: 5000 });
    const match = output.match(/http:\/\/127\.0\.0\.1:(\d+)\//);
    if (match) return parseInt(match[1]);
  } catch {}
  return null;
}

const FOUNDRY_PORT = parseInt(process.env.FOUNDRY_PORT) || detectFoundryPort() || 49296;
const LISTEN_PORT  = parseInt(process.env.PROXY_PORT || '5272');

const MODEL_MAP = {
  'gpt-4.1':    'Phi-4-generic-cpu:1',
  'gpt-5-mini': 'Phi-3.5-mini-instruct-generic-cpu:1',
};

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    // Rewrite model name in request body
    if (body) {
      try {
        const json = JSON.parse(body);
        if (json.model && MODEL_MAP[json.model]) {
          console.log(`  ↦ ${json.model} → ${MODEL_MAP[json.model]}`);
          json.model = MODEL_MAP[json.model];
        }
        body = JSON.stringify(json);
      } catch {}
    }

    const opts = {
      hostname: '127.0.0.1',
      port: FOUNDRY_PORT,
      path: req.url,
      method: req.method,
      headers: {
        ...req.headers,
        'content-length': Buffer.byteLength(body),
        host: `127.0.0.1:${FOUNDRY_PORT}`,
      },
    };

    const proxy = http.request(opts, upstream => {
      res.writeHead(upstream.statusCode, upstream.headers);
      upstream.pipe(res);
    });

    proxy.on('error', e => {
      console.error(`  ✗ Foundry unreachable on port ${FOUNDRY_PORT}: ${e.message}`);
      console.error(`    Is Foundry running? Try: foundry service start`);
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        error: {
          message: `Foundry Local unreachable on port ${FOUNDRY_PORT}. Run 'foundry service start' first.`,
          type: 'proxy_error',
          code: 'foundry_unreachable',
        }
      }));
    });

    if (body) proxy.write(body);
    proxy.end();
  });
});

server.listen(LISTEN_PORT, () => {
  console.log(`🔀 Foundry proxy: http://localhost:${LISTEN_PORT} → http://127.0.0.1:${FOUNDRY_PORT}`);
  console.log(`   Model map: ${Object.entries(MODEL_MAP).map(([k, v]) => `${k} → ${v}`).join(', ')}`);
  console.log(`   Ctrl+C to stop`);
});
