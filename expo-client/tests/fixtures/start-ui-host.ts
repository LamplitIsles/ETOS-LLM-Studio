/** Test-only entry point: a test-owned Metro port is required. */
import http from 'node:http';
import { createSeedProxy } from '../../scripts/seed-proxy.mjs';
import { startFixtureSeedHost } from './seed-host';

const [metroArg, proxyArg, ...extra] = process.argv.slice(2);
function port(value: string | undefined, allowZero: boolean): number {
  if (!value || !/^\d+$/.test(value)) throw new Error('Expected an explicit test-owned port');
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < (allowZero ? 0 : 1) || parsed > 65535 || [3090, 5173, 8081, 8082, 8091, 8092].includes(parsed)) throw new Error('Invalid or reserved test port');
  return parsed;
}
if (extra.length) throw new Error('Usage: tsx tests/fixtures/start-ui-host.ts <test-metro-port> [test-proxy-port]');
const metroPort = port(metroArg, false);
const proxyPort = port(proxyArg ?? '0', true);
if (proxyPort && proxyPort === metroPort) throw new Error('Metro and proxy ports must be different');
const extraMessages = Number(process.env.ETOS_UI_SYNTHETIC_EXTRA_MESSAGES ?? 0);
if (!Number.isInteger(extraMessages) || extraMessages < 0 || extraMessages > 1000) throw new Error('Invalid synthetic message count');
const replyScenario = process.env.ETOS_UI_REPLY_FIXTURE === '1';
const host = await startFixtureSeedHost(extraMessages, replyScenario);
const proxy: http.Server = createSeedProxy({
  seedRequest: host.request,
  testOnlyTtsFixture: true,
  metroRequest: async (options: http.RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: metroPort }),
});
const sockets = new Set<import('node:net').Socket>();
proxy.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
try {
  await new Promise<void>((resolve, reject) => {
    proxy.once('error', reject);
    proxy.listen(proxyPort, '127.0.0.1', resolve);
  });
} catch (error) {
  await host.close();
  throw error;
}
console.log(`Test-only fixture proxy: 127.0.0.1:${(proxy.address() as { port: number }).port} (test-owned Metro: 127.0.0.1:${metroPort}; browser origin remains http://127.0.0.1:8091)`);
if (extraMessages || replyScenario) console.log(`Test-only fixture control: 127.0.0.1:${host.controlPort}`);
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  proxy.closeAllConnections();
  for (const socket of sockets) socket.destroy();
  await new Promise<void>(resolve => proxy.close(() => resolve()));
  await host.close();
}
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => { void stop().catch(error => { console.error(error); process.exitCode = 1; }); });
