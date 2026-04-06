#!/usr/bin/env node
// hybrid-proxy.cjs — Routes model requests to cloud or local backends
// based on model name. Zero npm dependencies.
//
// Usage:  node hybrid-proxy.cjs [--config path/to/config.json]
//
// Config: hybrid-proxy.config.json (next to this script by default)

const http = require('http');
const https = require('https');
const path = require('path');
const fs = require('fs');
const { URL } = require('url');

// --- Load config ---
const configArg = process.argv.indexOf('--config');
const configPath = configArg !== -1 && process.argv[configArg + 1]
  ? path.resolve(process.argv[configArg + 1])
  : path.join(__dirname, 'hybrid-proxy.config.json');

if (!fs.existsSync(configPath)) {
  console.error(`✗ Config not found: ${configPath}`);
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const LISTEN_PORT = config.listenPort || 9090;
const BACKENDS = config.backends || {};
const ROUTES = config.routes || [];
const DEFAULT_BACKEND = config.defaultBackend || 'cloud';

// Headers forwarded in passthrough mode
const PASSTHROUGH_HEADERS = [
  'authorization', 'x-github-token', 'x-request-id',
  'user-agent', 'content-type', 'accept'
];

// --- Glob matching (supports * wildcard) ---
function globMatch(pattern, str) {
  if (pattern === str) return true;
  if (!pattern.includes('*')) return false;
  const regex = new RegExp(
    '^' + pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$'
  );
  return regex.test(str);
}

// --- Route a model name to a backend + optional rewrite ---
function resolveRoute(model) {
  // Routes are evaluated in order; first match wins.
  // "gpt-5-mini" is checked before "gpt-5*" because it appears first in config.
  for (const route of ROUTES) {
    if (globMatch(route.match, model)) {
      return {
        backend: route.backend,
        rewriteModel: route.rewriteModel || null,
      };
    }
  }
  return { backend: DEFAULT_BACKEND, rewriteModel: null };
}

// --- Build upstream request options ---
function buildUpstreamRequest(backendName, reqHeaders, method, urlPath, bodyBuf) {
  const backend = BACKENDS[backendName];
  if (!backend) {
    throw new Error(`Unknown backend: ${backendName}`);
  }

  const target = new URL(urlPath, backend.url);
  const isHttps = target.protocol === 'https:';
  const headers = {};

  if (backend.auth === 'passthrough') {
    for (const h of PASSTHROUGH_HEADERS) {
      if (reqHeaders[h]) headers[h] = reqHeaders[h];
    }
  } else {
    // static auth — strip all original auth, set our own
    if (reqHeaders['content-type']) headers['content-type'] = reqHeaders['content-type'];
    if (reqHeaders['accept']) headers['accept'] = reqHeaders['accept'];
    if (reqHeaders['user-agent']) headers['user-agent'] = reqHeaders['user-agent'];
    headers['authorization'] = `Bearer ${backend.apiKey}`;
  }

  headers['host'] = target.host;
  headers['content-length'] = bodyBuf.length;

  return {
    module: isHttps ? https : http,
    options: {
      hostname: target.hostname,
      port: target.port || (isHttps ? 443 : 80),
      path: target.pathname + target.search,
      method,
      headers,
    },
  };
}

// --- Collect all advertised model names ---
function getVirtualModels() {
  const models = [];
  const seen = new Set();

  for (const route of ROUTES) {
    // Use the match pattern as display name (without wildcards)
    if (!route.match.includes('*') && !seen.has(route.match)) {
      seen.add(route.match);
      models.push({
        id: route.match,
        object: 'model',
        created: Math.floor(Date.now() / 1000),
        owned_by: `hybrid-proxy:${route.backend}`,
      });
    }
  }

  // Add some well-known cloud models for wildcard routes
  const wildcardExpansions = {
    'claude-*': ['claude-sonnet-4.5', 'claude-sonnet-4', 'claude-opus-4.6'],
    'gpt-5*': ['gpt-5.1', 'gpt-5.2', 'gpt-5.4'],
  };
  for (const route of ROUTES) {
    if (route.match.includes('*') && wildcardExpansions[route.match]) {
      for (const name of wildcardExpansions[route.match]) {
        if (!seen.has(name)) {
          seen.add(name);
          models.push({
            id: name,
            object: 'model',
            created: Math.floor(Date.now() / 1000),
            owned_by: `hybrid-proxy:${route.backend}`,
          });
        }
      }
    }
  }

  return models;
}

// --- HTTP server ---
const server = http.createServer((req, res) => {
  // GET /v1/models — return virtual model list
  if (req.method === 'GET' && req.url === '/v1/models') {
    const models = getVirtualModels();
    const body = JSON.stringify({ object: 'list', data: models });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': body.length });
    res.end(body);
    return;
  }

  // Collect body
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks);
    let bodyBuf = rawBody;
    let model = null;
    let routeInfo = { backend: DEFAULT_BACKEND, rewriteModel: null };

    // Parse model from POST body
    if (rawBody.length > 0 && req.method === 'POST') {
      try {
        const json = JSON.parse(rawBody.toString('utf8'));
        model = json.model;
        if (model) {
          routeInfo = resolveRoute(model);
          // Rewrite model name if configured
          if (routeInfo.rewriteModel) {
            json.model = routeInfo.rewriteModel;
            const rewritten = JSON.stringify(json);
            bodyBuf = Buffer.from(rewritten, 'utf8');
            console.error(`  ↦ ${model} → ${routeInfo.rewriteModel} [${routeInfo.backend}]`);
          } else {
            console.error(`  → ${model} [${routeInfo.backend}]`);
          }
        }
      } catch {
        // Not JSON — forward as-is
      }
    }

    let upstream;
    try {
      upstream = buildUpstreamRequest(
        routeInfo.backend, req.headers, req.method, req.url, bodyBuf
      );
    } catch (e) {
      console.error(`  ✗ ${e.message}`);
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: e.message, type: 'proxy_error' } }));
      return;
    }

    const proxyReq = upstream.module.request(upstream.options, upstreamRes => {
      // Stream the response directly — no buffering
      res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
      upstreamRes.pipe(res);
    });

    proxyReq.on('error', e => {
      const backendUrl = BACKENDS[routeInfo.backend]?.url || 'unknown';
      console.error(`  ✗ ${routeInfo.backend} unreachable (${backendUrl}): ${e.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          error: {
            message: `Backend '${routeInfo.backend}' unreachable at ${backendUrl}: ${e.message}`,
            type: 'proxy_error',
            code: 'backend_unreachable',
          }
        }));
      }
    });

    proxyReq.write(bodyBuf);
    proxyReq.end();
  });
});

server.listen(LISTEN_PORT, () => {
  console.error(`🔀 Hybrid proxy listening on http://localhost:${LISTEN_PORT}`);
  console.error(`   Backends:`);
  for (const [name, b] of Object.entries(BACKENDS)) {
    console.error(`     ${name}: ${b.url} (auth: ${b.auth})`);
  }
  console.error(`   Routes:`);
  for (const r of ROUTES) {
    const rw = r.rewriteModel ? ` → ${r.rewriteModel}` : '';
    console.error(`     ${r.match} → ${r.backend}${rw}`);
  }
  console.error(`   Default: ${DEFAULT_BACKEND}`);
});
