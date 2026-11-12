/** Test-owned, in-memory CFL-shaped host. Never targets a real service. */
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import { WebSocketServer } from 'ws';
import { createChatHost, type ChatBackend, type ChatChange } from '../../vendor/contracts/src/server';
import { createFixture } from './fixture';

export async function startFixtureSeedHost(extraMessages = 0, replyScenario = false) {
  const fixture = createFixture();
  const firstTime = fixture.read().messages[0]?.createdAt ?? 0;
  const syntheticHistory = Array.from({ length: extraMessages }, (_, index) => {
    const text = `合成消息 ${String(index).padStart(3, '0')}：${'一段可变长度的历史内容。'.repeat(1 + index % 4)}`;
    return { id: `timeline-fixture-${index}`, role: index % 2 ? 'agent' as const : 'user' as const,
      text, ...(index % 2 ? { ends: [text.length] } : {}),
      createdAt: firstTime - (extraMessages - index) * 1000, operationId: null, turnId: null };
  });
  const scope = Symbol('fixture-seed-session');
  let publishReply: ((change: ChatChange) => void) | undefined;
  const backend = {
    async read() { return fixture.read(); },
    subscribe(changed: (change: ChatChange) => void) {
      publishReply = changed;
      const close = fixture.subscribe(view => changed({ type: 'update', scope, window: { messages: view.messages, before: view.before } }));
      const closeReceipts = fixture.subscribeReceipts(receipt => changed({ type: 'deliveryResult', scope, receipt }));
      return { scope, close() { publishReply = undefined; close(); closeReceipts(); } };
    },
    async history(before: string) {
      if (!extraMessages || before === 'timeline-original') return fixture.port.history(before);
      const end = before === 'fixture-older' ? syntheticHistory.length : Number(before.replace('timeline-page-', ''));
      if (!Number.isInteger(end) || end < 1 || end > syntheticHistory.length) throw new Error('invalid_fixture_cursor');
      const start = Math.max(0, end - 30);
      return { messages: syntheticHistory.slice(start, end), before: start ? `timeline-page-${start}` : 'timeline-original' };
    },
    submit: fixture.port.submit,
    lookup: fixture.port.lookup,
    search: fixture.port.search,
    searchRead: fixture.port.searchRead,
  } as unknown as ChatBackend;
  const host = await createChatHost(backend, error => { throw error; });
  let state: 'setup' | 'signed_out' | 'signed_in' = 'signed_in';
  let syntheticSequence = 0;
  const server = http.createServer((req, res) => {
    void (async () => {
      if (replyScenario && req.method === 'POST' && !req.headers.origin && /^\/__test\/reply\/[123]$/.test(req.url ?? '')) {
        const stage = Number(req.url!.at(-1));
        if (!publishReply) { res.writeHead(409).end(); return; }
        const id = 'fixture-stream-reply', createdAt = firstTime + 500000;
        const text = stage === 1 ? '第一句😀\n未完成' : '第一句😀\n第二句\n未完成';
        if (stage < 3) publishReply({ type: 'update', scope, state: { streamingReply: { id, createdAt, text, turnId: null } } });
        else publishReply({ type: 'update', scope, state: { streamingReply: null }, messages: [{ type: 'upsert', afterId: 'fixture-agent-sticker-message', message: { id, createdAt, text, role: 'agent', turnId: null, operationId: null } }] });
        res.writeHead(204).end(); return;
      }
      if (extraMessages && req.method === 'POST' && req.url === '/__test/append' && !req.headers.origin) {
        const operationId = `00000000-0000-4000-8000-${String(++syntheticSequence).padStart(12, '0')}`;
        await fixture.port.submit({ operationId, text: `合成实时消息 ${syntheticSequence}` });
        res.writeHead(204).end(); return;
      }
      if (req.method === 'GET' && req.url === '/api/auth/status') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ mode: 'passkey', state }));
        return;
      }
      if (state !== 'signed_in') { res.writeHead(401).end(); return; }
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      const method = req.method ?? 'GET';
      const body = Buffer.concat(chunks);
      const response = await fixture.media.request(req.url ?? '/', {
        method, headers: { 'content-type': req.headers['content-type'] ?? 'application/octet-stream' },
        ...(method === 'GET' ? {} : { body: method === 'PUT' || /^\/api\/background-settings\/(?:landscape|portrait)$/.test(req.url ?? '') ? new Blob([new Uint8Array(body)]) : body.toString() }),
      });
      res.writeHead(response.status, { 'content-type': response.headers.get('content-type') ?? 'application/octet-stream' });
      res.end(Buffer.from(await response.arrayBuffer()));
    })().catch(() => { if (!res.headersSent) res.writeHead(500); res.end(); });
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    if (req.url !== '/api/chat/socket' || state !== 'signed_in') { socket.end('HTTP/1.1 403 Forbidden\r\n\r\n'); return; }
    wss.handleUpgrade(req, socket, head, ws => {
      const peer = host.connect({ send(data) { ws.send(data); }, close() { ws.close(); } }, async () => true);
      ws.on('message', data => { void peer.receive(data.toString()); });
      ws.on('close', () => peer.close());
    });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = (server.address() as { port: number }).port;
  return {
    controlPort: port,
    /** Use only with the test-only createSeedProxy request seam. */
    async request(options: RequestOptions) { return http.request({ ...options, hostname: '127.0.0.1', port }); },
    setStatus(value: typeof state) { state = value; },
    async close() {
      host.close(); for (const client of wss.clients) client.terminate();
      wss.close(); server.closeAllConnections();
      await new Promise<void>(resolve => server.close(() => resolve()));
    },
  };
}
