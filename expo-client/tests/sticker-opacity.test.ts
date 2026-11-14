import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classifyStickerOpacityCore, inspectStaticSticker, type StickerOpacity } from '../src/cfl/sticker-opacity-core';

const image = (file: string, contentType: string) => ({ bytes: new Uint8Array(readFileSync(new URL(`./fixtures/opacity/${file}`, import.meta.url))), contentType });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }

test('static signatures and exact dimensions are identified without treating alpha as transparency', async () => {
  for (const [file, type] of [['rgb.png', 'image/png'], ['rgba-opaque.png', 'image/png'], ['rgba-transparent.png', 'image/png'], ['opaque.jpg', 'image/jpeg'], ['opaque.webp', 'image/webp'], ['transparent.webp', 'image/webp']] as const) {
    const value = image(file, type);
    assert.deepEqual(inspectStaticSticker(value), { width: 4, height: 4, contentType: type }, file);
    let calls = 0;
    assert.equal(await classifyStickerOpacityCore(value, () => true, undefined, async () => { calls++; return 'opaque'; }), 'opaque');
    assert.equal(calls, 1);
  }
});

test('animation, incorrect MIME, malformed files and oversized input never reach the decoder', async () => {
  const png = image('rgb.png', 'image/png');
  const huge = { ...png, bytes: png.bytes.slice() }; new DataView(huge.bytes.buffer).setUint32(16, 4097);
  const animatedPng = { ...png, bytes: new Uint8Array([...png.bytes.subarray(0, 33), 0,0,0,8, 97,99,84,76, 0,0,0,2,0,0,0,0, 0,0,0,0, ...png.bytes.subarray(33)]) };
  const cases = [image('animated.gif', 'image/gif'), image('animated.webp', 'image/webp'), image('animated.png', 'image/png'), image('rgba16.png', 'image/png'), animatedPng,
    { ...png, contentType: 'image/jpeg' }, { ...png, bytes: png.bytes.subarray(0, png.bytes.length - 1) }, huge,
    { ...png, bytes: new Uint8Array(8_000_001) }, { ...png, bytes: new Uint8Array(0) }];
  let calls = 0;
  for (const value of cases) assert.equal(await classifyStickerOpacityCore(value, () => true, undefined, async () => { calls++; return 'opaque'; }), 'unknown');
  assert.equal(calls, 0);
});

test('decode failure, unknown results, cancellation and late scope invalidation are unknown', async () => {
  const value = image('rgba-transparent.png', 'image/png');
  assert.equal(await classifyStickerOpacityCore(value, () => true, undefined, async () => { throw Error('decode'); }), 'unknown');
  assert.equal(await classifyStickerOpacityCore(value, () => true, undefined, async () => 'unexpected' as StickerOpacity), 'unknown');
  let active = true; const running = deferred<StickerOpacity>();
  const promise = classifyStickerOpacityCore(value, () => active, undefined, () => running.promise);
  active = false; running.resolve('opaque'); assert.equal(await promise, 'unknown');
  const abort = new AbortController(); abort.abort(); let called = false;
  assert.equal(await classifyStickerOpacityCore(value, () => true, abort.signal, async () => { called = true; return 'opaque'; }), 'unknown');
  assert.equal(called, false);
  const runningAbort = new AbortController(), delayed = deferred<StickerOpacity>();
  const cancelled = classifyStickerOpacityCore(value, () => true, runningAbort.signal, () => delayed.promise);
  runningAbort.abort(); delayed.resolve('transparent'); assert.equal(await cancelled, 'unknown');
});

test('queued cancellation frees its slot, serial decoding uses a stable byte copy and scope is rechecked', async () => {
  const value = image('rgba-opaque.png', 'image/png');
  const first = deferred<StickerOpacity>(); let active = true, calls = 0, decodedByte = -1;
  const running = classifyStickerOpacityCore(value, () => true, undefined, () => { calls++; return first.promise; });
  const abort = new AbortController();
  const queued = classifyStickerOpacityCore(value, () => true, abort.signal, async () => { calls++; return 'opaque'; });
  const stable = classifyStickerOpacityCore(value, () => true, undefined, async v => { calls++; decodedByte = v.bytes[0]; return 'opaque'; });
  const stale = classifyStickerOpacityCore(value, () => active, undefined, async () => { calls++; return 'opaque'; });
  value.bytes[0] = 0; abort.abort(); assert.equal(await queued, 'unknown'); active = false;
  first.resolve('transparent');
  assert.equal(await running, 'transparent'); assert.equal(await stable, 'opaque'); assert.equal(await stale, 'unknown');
  assert.equal(decodedByte, 137); assert.equal(calls, 2);
});

test('bounded queue rejects excess work and recovers after cancellation', async () => {
  const value = image('rgb.png', 'image/png'), first = deferred<StickerOpacity>(); let calls = 0;
  const running = classifyStickerOpacityCore(value, () => true, undefined, () => { calls++; return first.promise; });
  const abort = new AbortController();
  const queued = Array.from({ length: 8 }, () => classifyStickerOpacityCore(value, () => true, abort.signal, async () => { calls++; return 'opaque'; }));
  assert.equal(await classifyStickerOpacityCore(value, () => true, undefined, async () => { calls++; return 'opaque'; }), 'unknown');
  abort.abort(); assert.deepEqual(await Promise.all(queued), Array(8).fill('unknown'));
  const after = classifyStickerOpacityCore(value, () => true, undefined, async () => { calls++; return 'opaque'; });
  first.resolve('opaque'); assert.equal(await running, 'opaque'); assert.equal(await after, 'opaque'); assert.equal(calls, 2);
});

test('actual controller original media read is classified without another request and old session results are discarded', async () => {
  const { createFixture } = await import('./fixtures/fixture');
  const fixture = createFixture(); const calls: string[] = [];
  const source = image('rgba-transparent.png', 'image/png');
  const media = { origin: 'fixture://local', async read(path: string) { calls.push(path); return new Response(source.bytes, { headers: { 'content-type': source.contentType } }); } };
  await fixture.controller.start();
  try {
    const current = fixture.controller.scope();
    const loaded = await fixture.controller.readImage(media, 'fixture-image', current, 'original');
    const pending = deferred<StickerOpacity>();
    const classified = classifyStickerOpacityCore(loaded, current, undefined, () => pending.promise);
    fixture.controller.stop(); pending.resolve('transparent');
    assert.equal(await classified, 'unknown');
    assert.deepEqual(calls, ['/api/chat/media/fixture-image/original']);
  } finally { fixture.controller.stop(); }
});

test('native method seam fails closed on old binaries and validates native outcomes', async () => {
  const { classifyStickerOpacityWithNative } = await import('../src/cfl/sticker-opacity-native-core');
  const value = image('rgba-opaque.png', 'image/png');
  assert.equal(await classifyStickerOpacityWithNative(value, () => true, undefined, () => null), 'unknown');
  assert.equal(await classifyStickerOpacityWithNative(value, () => true, undefined, () => ({})), 'unknown');
  assert.equal(await classifyStickerOpacityWithNative(value, () => true, undefined, () => { throw Error('unavailable'); }), 'unknown');
  let seen = false;
  assert.equal(await classifyStickerOpacityWithNative(value, () => true, undefined, () => ({ async classifyStaticImageOpacity(bytes, type, width, height) {
    seen = true; assert.equal(bytes[0], 137); assert.equal(type, 'image/png'); assert.equal(width, 4); assert.equal(height, 4); return 'opaque';
  } })), 'opaque');
  assert.equal(seen, true);
  assert.equal(await classifyStickerOpacityWithNative(value, () => true, undefined, () => ({ async classifyStaticImageOpacity() { return 'invalid'; } })), 'unknown');
});

test('queued byte budget rejects oversized backlog even before the count limit', async () => {
  const original = image('rgb.png', 'image/png'), total = 6_000_000;
  const bytes = new Uint8Array(total), split = original.bytes.length - 12;
  bytes.set(original.bytes.subarray(0, split));
  const chunkSize = total - original.bytes.length - 12;
  new DataView(bytes.buffer).setUint32(split, chunkSize);
  bytes.set([116, 69, 88, 116], split + 4); // test-only ancillary chunk
  bytes.set(original.bytes.subarray(split), total - 12);
  const large = { bytes, contentType: 'image/png' };
  assert.ok(inspectStaticSticker(large));
  const held = deferred<StickerOpacity>();
  const running = classifyStickerOpacityCore(original, () => true, undefined, () => held.promise);
  const abort = new AbortController();
  const queued = [1, 2].map(() => classifyStickerOpacityCore(large, () => true, abort.signal, async () => 'opaque'));
  let calls = 0;
  assert.equal(await classifyStickerOpacityCore(large, () => true, undefined, async () => { calls++; return 'opaque'; }), 'unknown');
  abort.abort(); assert.deepEqual(await Promise.all(queued), ['unknown', 'unknown']);
  held.resolve('opaque'); assert.equal(await running, 'opaque'); assert.equal(calls, 0);
});
