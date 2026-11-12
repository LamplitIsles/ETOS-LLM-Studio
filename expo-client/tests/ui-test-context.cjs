// Route every browser request through a separately started test-only seed proxy.
// The virtual origin is required by the development seed guard; it is never
// contacted directly, including for WebSockets.
const WebSocket = require('ws');

async function isolatedContext(browser, options, statusOverride) {
  const port = Number(process.env.ETOS_UI_PROXY_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || [3090, 5173, 8081, 8082, 8091, 8092].includes(port)) {
    throw new Error('Set ETOS_UI_PROXY_PORT to the independent test-only proxy port.');
  }
  const context = await browser.newContext(options);
  await context.route('**/*', async route => {
    const original = new URL(route.request().url());
    if (original.origin !== 'http://127.0.0.1:8091') return route.abort();
    if (original.pathname === '/api/auth/status' && statusOverride) {
      if (statusOverride === 'unavailable') return route.fulfill({ status: 503 });
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ mode: 'passkey', state: statusOverride }) });
    }
    const target = `http://127.0.0.1:${port}${original.pathname}${original.search}`;
    const headers = { ...route.request().headers(), host: '127.0.0.1:8091' };
    try { await route.fulfill({ response: await route.fetch({ url: target, headers, timeout: 120000 }) }); }
    catch { await route.abort(); }
  });
  await context.routeWebSocket('**/*', socket => {
    const original = new URL(socket.url());
    if (original.host !== '127.0.0.1:8091') { socket.close(); return; }
    const remote = new WebSocket(`ws://127.0.0.1:${port}${original.pathname}${original.search}`, {
      headers: { Host: '127.0.0.1:8091', Origin: 'http://127.0.0.1:8091' },
    });
    const pending = [];
    remote.on('open', () => { for (const message of pending) remote.send(message); });
    remote.on('message', (data, binary) => socket.send(binary ? data : data.toString()));
    remote.on('error', () => socket.close());
    remote.on('close', () => socket.close());
    socket.onMessage(message => { if (remote.readyState === WebSocket.OPEN) remote.send(message); else if (remote.readyState === WebSocket.CONNECTING) pending.push(message); });
    socket.onClose(() => remote.close());
  });
  return context;
}
module.exports = { isolatedContext };
