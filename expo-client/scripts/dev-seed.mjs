// Explicit synthetic Web development mode. Metro and the proxy stay on loopback.
import { spawn } from 'node:child_process';
import { createSeedProxy, seedRequest, metroRequest, verifySeedHost } from './seed-proxy.mjs';
import { isPrivateIPv4 } from '../src/cfl/seed-address.js';

const lanHost = process.env.ETOS_SEED_LAN_HOST;
if (lanHost && !isPrivateIPv4(lanHost)) throw new Error('ETOS_SEED_LAN_HOST must be one RFC1918 IPv4 address');
await verifySeedHost();
const server = createSeedProxy({ seedRequest, metroRequest, lanHost });
const connections = new Set();
server.on('connection', socket => { connections.add(socket); socket.on('close', () => connections.delete(socket)); });
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(8091, '127.0.0.1', resolve); });
// Web HMR and asset URLs must follow the browser's Host (including the
// forwarded LAN address), never a fixed public URL inherited from the environment.
const env = { ...process.env, EXPO_PUBLIC_ETOS_SYNTHETIC_SEED: '1', EXPO_PUBLIC_ETOS_SEED_LAN_HOST: lanHost ?? '' };
delete env.EXPO_PACKAGER_PROXY_URL;
const child = spawn(process.execPath, ['node_modules/expo/bin/cli', 'start', '--localhost', '--port', '8092', '--max-workers', '2'], {
  stdio: 'inherit', env,
});
console.log('Synthetic seed proxy: http://localhost:8091 (Metro 8092; CFL fixture 3090)');
let stopping = false;
function closeProxy() { server.close(); for (const socket of connections) socket.destroy(); }
function stop() { if (stopping) return; stopping = true; child.kill('SIGTERM'); closeProxy(); }
process.on('SIGINT', stop); process.on('SIGTERM', stop);
child.on('error', error => { console.error(error); stop(); process.exitCode = 1; });
child.on('exit', (code, signal) => { closeProxy(); if (!stopping) process.exitCode = code ?? (signal ? 1 : 0); });
