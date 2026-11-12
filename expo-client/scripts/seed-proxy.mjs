// Development-only loopback reverse proxy. There is no configurable seed URL.
import http from 'node:http';
import { execFile } from 'node:child_process';
import { readFile, readlink } from 'node:fs/promises';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { isPrivateIPv4 } from '../src/cfl/seed-address.js';
import { isSeedApiRequest, isTestTtsFixtureRequest } from '../src/cfl/seed-paths.js';

const execFileAsync = promisify(execFile);
const marker = 'CFL synthetic frontend development fixture v1\n';

// Refuse to connect if port 3090 is not the known CFL test host. The test
// host has no auth; a successful /status response alone is not proof of it.
// Linux only, intentionally fail closed if process ownership cannot be read.
export async function verifySeedHost() {
  const { stdout } = await execFileAsync('ss', ['-H', '-ltnp', '( sport = :3090 )']);
  const lines = stdout.trim().split('\n');
  const match = lines.length === 1 && lines[0].match(/^LISTEN\s+\d+\s+\d+\s+127\.0\.0\.1:3090\s+\S+\s+.*pid=(\d+),/);
  if (!match) throw new Error('3090 is not a single inspectable loopback listener');
  const pid = match[1];
  const args = (await readFile(`/proc/${pid}/cmdline`, 'utf8')).split('\0').filter(Boolean);
  if (args.length !== 4 || !/(?:^|\/)node(?:js)?$/.test(args[0]) || args[1] !== 'apps/partner/tests/frontend-development-host.ts' || args[2] !== 'start' || args[3] !== '3090') throw new Error('3090 is not the CFL synthetic development host');
  const cwd = await readlink(`/proc/${pid}/cwd`);
  const state = join(cwd, '.scratch/frontend-development-fixture/state');
  if (await readFile(join(state, 'MARKER'), 'utf8') !== marker || (await readFile(join(state, 'LOCK/pid'), 'utf8')).trim() !== pid) throw new Error('CFL synthetic fixture identity does not match its lock');
}

function permitted(req, lanHost) {
  const host = req.headers.host;
  const safe = host === 'localhost:8091' || host === '127.0.0.1:8091' || (lanHost && host === `${lanHost}:8091`);
  return safe && (!req.headers.origin || req.headers.origin === `http://${host}`) && req.headers['sec-fetch-site'] !== 'cross-site';
}
function isApi(url) { return url === '/api' || url.startsWith('/api/') || url.startsWith('/api?'); }
function headers(req, seed, conditionalMedia = false) {
  if (!seed) return { ...req.headers };
  const allowed = ['host', 'origin', 'sec-fetch-site', 'accept', 'connection', 'upgrade', 'sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol', 'sec-websocket-extensions', 'content-type', 'content-length'];
  if (conditionalMedia) allowed.push('if-none-match');
  return Object.fromEntries(Object.entries(req.headers).filter(([key]) => allowed.includes(key)));
}
function responseHeaders(input, seed) {
  const output = { ...input };
  if (seed) for (const key of Object.keys(output)) if (key === 'set-cookie' || key.startsWith('access-control-')) delete output[key];
  return output;
}

// Injected request functions are test seams, not network destination options.
// Production callers always use the two hard-coded loopback endpoints below.
/** @param {{seedRequest: Function, metroRequest: Function, lanHost?: string, testOnlyTtsFixture?: boolean}} options */
export function createSeedProxy({ seedRequest: upstreamSeed, metroRequest, lanHost, testOnlyTtsFixture = false }) {
  if (testOnlyTtsFixture && upstreamSeed === seedRequest) throw new Error('Test TTS is forbidden for the fixed seed');
  if (lanHost && !isPrivateIPv4(lanHost)) throw new Error('LAN host must be an RFC1918 IPv4 address');
  const server = http.createServer((req, res) => {
    if (!permitted(req, lanHost)) { req.resume(); res.writeHead(403).end(); return; }
    const url = req.url ?? '/';
    const seed = isApi(url);
    if (seed && !testOnlyTtsFixture && isTestTtsFixtureRequest(req.method, url)) {
      req.resume(); res.writeHead(404, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify({ error: { code: 'tts_unsupported' } })); return;
    }
    if (seed && (!(isSeedApiRequest(req.method, url) || (testOnlyTtsFixture && isTestTtsFixtureRequest(req.method, url))) || (req.method !== 'GET' && !req.headers.origin))) { req.resume(); res.writeHead(404).end(); return; }
    const conditionalMedia = seed && req.method === 'GET' && (
      /^\/api\/stickers\/media\/[a-f0-9]{64}\/(?:thumbnail|original)$/.test(url) ||
      /^\/api\/chat\/media\/[A-Za-z0-9_-]{1,100}\/(?:preview|original)$/.test(url)
    );
    const go = async () => {
      const upstream = await (seed ? upstreamSeed : metroRequest)({ method: req.method, path: url, headers: headers(req, seed, conditionalMedia) });
      upstream.on('response', response => {
        const notModified = conditionalMedia && typeof req.headers['if-none-match'] === 'string' && req.headers['if-none-match'].trim() !== '' && response.statusCode === 304 && !Object.hasOwn(response.headers, 'location');
        if (seed && response.statusCode >= 300 && response.statusCode < 400 && !notModified) { response.resume(); res.writeHead(502).end(); return; }
        res.writeHead(response.statusCode ?? 502, responseHeaders(response.headers, seed)); response.pipe(res);
      });
      upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
      req.pipe(upstream);
    };
    void go().catch(() => { if (!res.headersSent) res.writeHead(502); res.end(); });
  });
  server.on('upgrade', (req, socket, head) => {
    const url = req.url ?? '/'; const seed = isApi(url);
    if (!permitted(req, lanHost) || !req.headers.origin || (seed && url !== '/api/chat/socket')) { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return; }
    const go = async () => {
      const upstream = await (seed ? upstreamSeed : metroRequest)({ method: 'GET', path: url, headers: headers(req, seed) });
      upstream.on('upgrade', (response, peer, upstreamHead) => {
        const clean = responseHeaders(response.headers, seed);
        socket.write(`HTTP/1.1 101 Switching Protocols\r\n${Object.entries(clean).flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map(value => `${k}: ${value}\r\n`)).join('')}\r\n`);
        if (upstreamHead.length) socket.write(upstreamHead);
        if (head.length) peer.write(head);
        socket.on('error', () => peer.destroy()); peer.on('error', () => socket.destroy());
        socket.pipe(peer).pipe(socket);
      });
      upstream.on('response', response => { response.resume(); socket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n'); });
      upstream.on('error', () => socket.destroy());
      upstream.end();
    };
    void go().catch(() => socket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n'));
  });
  return server;
}
export const seedRequest = async options => { await verifySeedHost(); return http.request({ ...options, hostname: '127.0.0.1', port: 3090 }); };
export const metroRequest = async options => http.request({ ...options, hostname: '127.0.0.1', port: 8092 });
