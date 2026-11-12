import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import WebSocket, { WebSocketServer } from 'ws';

test('UI fixture entry uses isolated ports and preserves browser host for HTTP and WebSocket', async t => {
  const metro = http.createServer((req, res) => { res.end(`asset:${req.headers.host}`); });
  const wss = new WebSocketServer({ noServer: true });
  metro.on('upgrade', (req, socket, head) => wss.handleUpgrade(req, socket, head, ws => ws.on('message', data => ws.send(data))));
  metro.listen(0, '127.0.0.1'); await once(metro, 'listening');
  const metroPort = (metro.address() as { port: number }).port;
  const child = spawn(process.execPath, ['--import', 'tsx', 'tests/fixtures/start-ui-host.ts', String(metroPort)], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => { if (child.exitCode === null) { child.kill('SIGTERM'); await once(child, 'exit'); } wss.close(); metro.closeAllConnections(); await new Promise<void>(resolve => metro.close(() => resolve())); });
  let output = '';
  const proxyPort = await new Promise<number>((resolve, reject) => {
    const timer = setTimeout(() => reject(Error(`fixture host did not start: ${output}`)), 5000);
    child.stdout.on('data', chunk => {
      output += chunk.toString();
      const match = output.match(/Test-only fixture proxy: 127\.0\.0\.1:(\d+)/);
      if (match) { clearTimeout(timer); resolve(Number(match[1])); }
    });
    child.stderr.on('data', chunk => { output += chunk.toString(); });
    child.on('exit', code => { clearTimeout(timer); reject(Error(`fixture host exited ${code}: ${output}`)); });
  });
  assert.notEqual(proxyPort, metroPort);
  const get = (path: string) => new Promise<string>((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: proxyPort, path, headers: { host: '127.0.0.1:8091', origin: 'http://127.0.0.1:8091' } }, res => { let body = ''; res.on('data', chunk => { body += chunk; }); res.on('end', () => resolve(body)); }).on('error', reject);
  });
  assert.equal(await get('/index.bundle'), 'asset:127.0.0.1:8091');
  assert.equal(JSON.parse(await get('/api/auth/status')).state, 'signed_in');
  const socket = new WebSocket(`ws://127.0.0.1:${proxyPort}/message`, { headers: { Host: '127.0.0.1:8091', Origin: 'http://127.0.0.1:8091' } });
  await once(socket, 'open'); socket.send('reload');
  const [message] = await once(socket, 'message'); assert.equal(message.toString(), 'reload');
  socket.terminate();
});

test('test fixture rejects old and new shared service ports before starting', async () => {
  const { isolatedContext } = createRequire(import.meta.url)('./ui-test-context.cjs') as { isolatedContext: (browser: unknown, options: object) => Promise<unknown> };
  const previous = process.env.ETOS_UI_PROXY_PORT;
  try {
    for (const port of [3090, 5173, 8081, 8082, 8091, 8092]) {
      for (const args of [[String(port)], ['18092', String(port)]]) {
        const result = spawnSync(process.execPath, ['--import', 'tsx', 'tests/fixtures/start-ui-host.ts', ...args], { encoding: 'utf8', timeout: 10000 });
        assert.notEqual(result.status, 0, `accepted reserved ${port}`);
        assert.match(result.stderr, /Invalid or reserved test port/);
      }
      process.env.ETOS_UI_PROXY_PORT = String(port);
      await assert.rejects(isolatedContext({}, {}), /independent test-only proxy port/);
    }
  } finally {
    if (previous === undefined) delete process.env.ETOS_UI_PROXY_PORT; else process.env.ETOS_UI_PROXY_PORT = previous;
  }
});
