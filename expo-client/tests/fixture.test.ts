import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';
import { createFixture } from './fixtures/fixture';
import { loadImage } from '../src/cfl/transport';

test('synthetic conversation responds deterministically and survives reconnection without duplicates', async () => {
  const operation = '00000000-0000-4000-8000-000000000123';
  const { controller } = createFixture({ newOperationId: () => operation });
  await controller.start();
  await controller.loadOlder();
  assert.match(controller.snapshot().history[0]!.text, /周末/);
  assert.equal(await controller.send('最近有点忙'), operation);
  assert.equal(await controller.send('最近有点忙'), operation);
  const snapshot = controller.snapshot();
  const userMessages = snapshot.view!.messages.filter(message => message.operationId === operation);
  const replies = snapshot.view!.messages.filter(message => message.id === `fixture-reply-${operation}`);
  assert.equal(userMessages.length, 1);
  assert.equal(userMessages[0]!.id, `fixture-${operation}`);
  assert.equal(userMessages[0]!.text, '最近有点忙');
  assert.equal(replies.length, 1);
  assert.equal(replies[0]!.text, '辛苦了，先给自己一点休息的时间吧。');
  assert.deepEqual(replies[0]!.ends, [replies[0]!.text.length]);
  assert.equal(snapshot.pending.length, 0);
  controller.stop();
  await controller.start();
  assert.equal(controller.snapshot().view?.sessionId, 'fixture-session');
  assert.equal(controller.snapshot().view!.messages.filter(message => message.operationId === operation).length, 1);
  assert.equal(controller.snapshot().view!.messages.filter(message => message.id === `fixture-reply-${operation}`).length, 1);
  controller.stop();
});

test('fixture returns original nontrivial PNG without network and isolates sessions', async () => {
  const { controller, media } = createFixture();
  const other = createFixture();
  const originalFetch = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => { requests++; throw new Error('unexpected network'); };
  try {
    await controller.start();
    await controller.send('你好');
    await other.controller.start();
    assert.equal(other.controller.snapshot().view!.messages.some(message => message.text === '你好'), false);
    const { bytes, contentType } = await loadImage(media, 'fixture-image', controller.scope());
    assert.equal(contentType, 'image/png');
    const data = Buffer.from(bytes);
    assert.deepEqual(data.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    assert.equal(data.readUInt32BE(16), 240);
    assert.equal(data.readUInt32BE(20), 180);
    const chunks: Buffer[] = [];
    for (let offset = 8; offset < data.length;) {
      const length = data.readUInt32BE(offset);
      const type = data.toString('ascii', offset + 4, offset + 8);
      if (type === 'IDAT') chunks.push(data.subarray(offset + 8, offset + 8 + length));
      offset += 12 + length;
    }
    const pixels = inflateSync(Buffer.concat(chunks));
    const colors = new Set<string>();
    for (let y = 0; y < 180; y++) for (let x = 0; x < 240; x++) {
      const offset = y * (1 + 240 * 3) + 1 + x * 3;
      colors.add(pixels.subarray(offset, offset + 3).toString('hex'));
    }
    assert.ok(colors.size > 10, `expected varied image, got ${colors.size} colors`);
    assert.equal(requests, 0);
  } finally {
    globalThis.fetch = originalFetch;
    controller.stop(); other.controller.stop();
  }
});
