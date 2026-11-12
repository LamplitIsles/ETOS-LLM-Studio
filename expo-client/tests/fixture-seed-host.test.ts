import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createSeedProxy } from '../scripts/seed-proxy.mjs';
import { openChat } from '../vendor/contracts/src/client';
import type { ChatView } from '../vendor/contracts/src/index';
import { startFixtureSeedHost } from './fixtures/seed-host';
import { fixtureImageBase64 } from './fixtures/fixture-art';
import { fixtureWorkspaceImagePath } from './fixtures/fixture-attachments';

test('isolated fixture host serves seed status, chat protocol, history and staged media through the seed proxy', async t => {
  const host = await startFixtureSeedHost();
  const proxy: http.Server = createSeedProxy({ seedRequest: host.request, metroRequest: async () => { throw Error('no Metro in this test'); } });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(async () => { proxy.closeAllConnections(); await new Promise<void>(resolve => proxy.close(() => resolve())); await host.close(); });
  const port = (proxy.address() as { port: number }).port;
  async function request(path: string, method = 'GET', body?: string) {
    return await new Promise<{ status: number; body: Buffer }>((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port, path, method, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', 'content-type': 'application/json' } }, res => {
        const chunks: Buffer[] = []; res.on('data', chunk => chunks.push(chunk)); res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks) }));
      });
      req.on('error', reject); req.end(body);
    });
  }
  assert.deepEqual(JSON.parse((await request('/api/auth/status')).body.toString()), { mode: 'passkey', state: 'signed_in' });
  assert.equal((await request('/api/chat/media/fixture-image/preview')).status, 200);
  const workspacePath = `/api/chat/workspace-image?path=${encodeURIComponent(fixtureWorkspaceImagePath)}`;
  assert.equal((await request(workspacePath)).body.toString('base64'), fixtureImageBase64);
  for (const invalid of ['/api/chat/workspace-image', '/api/chat/workspace-image?path=x.png&x=1', '/api/chat/workspace-image?path=x.png&path=y.png', '/api/chat/workspace-image?path=%2E%2E%2Fprivate.png', '/api/chat/workspace-image?path=%ZZ.png', '/api/chat/workspace-image?path=x.svg']) assert.equal((await request(invalid)).status, 404, invalid);
  assert.equal((await request(workspacePath, 'POST', '{}')).status, 404);
  const packs = await request('/api/stickers/packs?sessionId=fixture-session&limit=30');
  assert.equal(JSON.parse(packs.body.toString()).packs[0].name, '小绿的日常');
  const favorite = (value: boolean) => request('/api/stickers/favorites', 'POST', JSON.stringify({ sessionId: 'fixture-session', stickerId: 'fixture-sticker', favorite: value }));
  assert.equal(JSON.parse((await favorite(false)).body.toString()).favorite, false);
  assert.equal(JSON.parse((await request('/api/stickers/favorites?sessionId=fixture-session&limit=30')).body.toString()).stickers.length, 0);
  assert.equal(JSON.parse((await favorite(true)).body.toString()).favorite, true);
  const favoriteImage = await request('/api/stickers/favorites/image', 'POST', JSON.stringify({ sessionId: 'fixture-session', imageId: 'fixture-image', name: '照片', tags: [] }));
  assert.equal(JSON.parse(favoriteImage.body.toString()).favorite, true);
  const imageVersion = JSON.parse(favoriteImage.body.toString()).sticker.version;
  assert.equal((await request(`/api/stickers/media/${imageVersion}/original`)).body.toString('base64'), fixtureImageBase64);
  const socket = new WebSocket(`ws://127.0.0.1:${port}/api/chat/socket`, { headers: { Host: 'localhost:8091', Origin: 'http://localhost:8091' } });
  let view: ChatView | undefined;
  const client = await openChat(socket as unknown as globalThis.WebSocket, value => { view = value; }, () => {});
  t.after(() => client.close());
  assert.equal(view?.sessionId, 'fixture-session');
  assert.match((await client.history('fixture-older')).messages[0].text, /周末/);
  const operationId = '00000000-0000-4000-8000-000000000001';
  const staged = await request('/api/stickers/stage', 'POST', JSON.stringify({ sessionId: 'fixture-session', operationId, sticker: { id: 'fixture-sticker', version: '0'.repeat(64) } }));
  assert.equal(staged.status, 200);
  const image = JSON.parse(staged.body.toString()).image;
  assert.equal((await request(`/api/chat/media/${image.attachmentId}/preview`)).status, 200);
  assert.equal((await client.submit({ operationId, text: '', images: [image] })).state, 'submitted');
  assert.equal((await client.lookup(operationId))?.state, 'submitted');
  await new Promise<void>((resolve, reject) => {
    const deadline = Date.now() + 2000;
    const check = () => view?.messages.some(message => message.operationId === operationId) ? resolve() : Date.now() > deadline ? reject(Error('missing fixture update')) : setTimeout(check, 10);
    check();
  });
  const attachmentOperation = '00000000-0000-4000-8000-000000000002';
  const uploaded = await request('/api/chat/images', 'POST', JSON.stringify({ sessionId: 'fixture-session', operationId: attachmentOperation, images: [{ id: 'photo', order: 0, name: 'lake.png', mediaType: 'image/png', original: fixtureImageBase64 }] }));
  assert.equal(uploaded.status, 200);
  const photo = JSON.parse(uploaded.body.toString()).images[0].ref;
  assert.equal((await request(`/api/chat/media/${photo.attachmentId}/preview`)).body.toString('base64'), fixtureImageBase64);
  const manifest = { sessionId: 'fixture-session', operationId: attachmentOperation, files: [{ id: 'doc', name: 'note.txt', mediaType: 'text/plain', size: 4 }] };
  assert.equal((await request('/api/chat/file-operations', 'POST', JSON.stringify(manifest))).status, 200);
  assert.equal((await request(`/api/chat/file-operations/${attachmentOperation}/files/doc`, 'PUT', 'test')).status, 204);
  const complete = await request(`/api/chat/file-operations/${attachmentOperation}/complete`, 'POST', '{}');
  assert.equal(complete.status, 200);
  const file = JSON.parse(complete.body.toString()).files[0].ref;
  assert.equal((await request(`/api/chat/files/${file.attachmentId}`)).body.toString(), 'test');
  assert.equal((await client.submit({ operationId: attachmentOperation, text: '', images: [photo], files: [file] })).state, 'submitted');
  client.close();
  host.setStatus('signed_out');
  assert.equal(JSON.parse((await request('/api/auth/status')).body.toString()).state, 'signed_out');
  assert.equal((await request('/api/chat/media/fixture-image/preview')).status, 401);
  assert.equal((await request(workspacePath)).status, 401);
});
