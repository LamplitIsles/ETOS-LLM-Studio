// Real browser fetch against a disposable, test-owned same-origin HTTP server.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { readFile } = require('node:fs/promises');
const path = require('node:path');
const ts = require('typescript');
const { chromium } = require('@playwright/test');

test('default WebAuth fetch works in a browser for status, pair and sign-out', async t => {
  const requests = [];
  const host = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      if (req.url === '/') return res.writeHead(200, { 'content-type': 'text/html' }).end('<!doctype html><title>synthetic auth test</title>');
      if (req.url === '/favicon.ico') return res.writeHead(204).end();
      requests.push({ path: req.url, method: req.method, body, cookie: req.headers.cookie });
      if (req.url === '/api/auth/status') return res.writeHead(200, { 'content-type': 'application/json' }).end('{"mode":"passkey","state":"signed_in"}');
      if (req.url === '/api/auth/pairing' || req.url === '/api/auth/sign-out') return res.writeHead(200, { 'content-type': 'application/json' }).end('{}');
      res.writeHead(404).end();
    });
  });
  host.listen(0, '127.0.0.1'); await once(host, 'listening');
  t.after(() => { host.closeAllConnections(); host.close(); });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] });
  t.after(() => browser.close());
  const context = await browser.newContext();
  const origin = `http://127.0.0.1:${host.address().port}`;
  await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
  const page = await context.newPage();
  await page.goto(`${origin}/`);
  const source = await readFile(path.join(__dirname, '../src/cfl/web-auth.ts'), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const result = await page.evaluate(async code => {
    const exports = {};
    const load = name => {
      if (name === 'better-auth/client') return { createAuthClient() { throw Error('unused'); } };
      if (name === '@better-auth/passkey/client') return { passkeyClient() { throw Error('unused'); } };
      throw Error('unexpected import');
    };
    const WebAuth = new Function('exports', 'require', `${code}\nreturn exports.WebAuth;`)(exports, load);
    let added = 0;
    const passkeys = { signIn: { async passkey() { return {}; } }, passkey: { async addPasskey(options) { if (!options.createSession) throw Error('wrong options'); added++; return {}; } } };
    const auth = new WebAuth(passkeys, undefined, () => true);
    const attempt = async fn => { try { return { value: await fn() }; } catch (error) { return { error: String(error) }; } };
    const status = await attempt(() => auth.status());
    const pair = await attempt(() => auth.pair('test-only-code'));
    const signOut = await attempt(() => auth.signOut());
    return { status, pair, signOut, added };
  }, compiled);
  assert.deepEqual(result, { status: { value: 'signed_in' }, pair: { value: undefined }, signOut: { value: undefined }, added: 1 });
  assert.deepEqual(requests.map(({ path, method, body, cookie }) => ({ path, method, body, cookie })), [
    { path: '/api/auth/status', method: 'GET', body: '', cookie: undefined },
    { path: '/api/auth/pairing', method: 'POST', body: '{"code":"test-only-code"}', cookie: undefined },
    { path: '/api/auth/status', method: 'GET', body: '', cookie: undefined },
    { path: '/api/auth/sign-out', method: 'POST', body: '{}', cookie: undefined },
  ]);
});
