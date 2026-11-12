import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFixture } from './fixtures/fixture';
import type { MediaTransport } from '../src/cfl/transport';

test('seventeen image mounts wait for capacity and cancellation starts the next visible image', async () => {
  const { controller } = createFixture(); await controller.start();
  const calls: { id: string; resolve: (response: Response) => void }[] = [];
  const media: MediaTransport = { origin: 'fixture://local', read(path, init) { return new Promise((resolve, reject) => { calls.push({ id: path.split('/')[4], resolve }); init?.signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })), { once: true }); }); } };
  const signals = Array.from({ length: 17 }, () => new AbortController());
  const promises = signals.map((signal, i) => controller.readImage(media, `image${i}`, () => !signal.signal.aborted, 'original', signal.signal));
  const results = promises.map(p => p.then(() => 'ready', error => error.message));
  try {
    assert.equal(calls.length, 16);
    signals[0].abort();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls.length, 17, 'the seventeenth visible image must start after cancellation');
    for (const call of calls) call.resolve(new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } }));
    const result = await Promise.all(results);
    assert.equal(result[0], 'aborted'); assert.equal(result[16], 'ready');
  } finally { controller.stop(); }
});

test('FIFO queue skips cancelled items and shares duplicate image work, never exceeding sixteen reads', async () => {
  const { controller } = createFixture(); await controller.start();
  const calls: { id: string; resolve: (response: Response) => void }[] = []; let inFlight = 0, peak = 0;
  const media: MediaTransport = { origin: 'fixture://local', read(path, init) { inFlight++; peak = Math.max(peak, inFlight); return new Promise((resolve, reject) => {
    calls.push({ id: path.split('/')[4], resolve: response => { inFlight--; resolve(response); } });
    init?.signal?.addEventListener('abort', () => { inFlight--; reject(Error('aborted')); }, { once: true });
  }); } };
  const controllers = Array.from({ length: 21 }, () => new AbortController());
  const results = controllers.map((c, i) => controller.readImage(media, `i${i}`, () => !c.signal.aborted, 'original', c.signal).then(() => 'ready', e => e.message));
  const duplicate = controller.readImage(media, 'i19', () => true, 'original').then(() => 'ready');
  const response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } });
  try {
    controllers[17].abort(); assert.equal(await results[17], 'aborted');
    for (let i = 0; i < 16; i++) { calls[i].resolve(response()); await new Promise(resolve => setImmediate(resolve)); }
    assert.deepEqual(calls.slice(16).map(c => c.id), ['i16', 'i18', 'i19', 'i20']);
    for (const call of calls.slice(16)) call.resolve(response());
    const settled = await Promise.all(results); assert.ok(settled.every((value, i) => i === 17 ? value === 'aborted' : value === 'ready'));
    assert.equal(await duplicate, 'ready'); assert.equal(peak, 16);
  } finally { controller.stop(); }
});

for (const status of [401, 403]) test(`${status} aborts running reads and rejects queued reads without starting them`, async () => {
  const { controller } = createFixture(); await controller.start(); let calls = 0; let fail!: (r: Response) => void;
  const media: MediaTransport = { origin: 'fixture://local', read(_path, init) { calls++; return new Promise((resolve, reject) => { if (calls === 1) fail = resolve; init?.signal?.addEventListener('abort', () => reject(Error('aborted')), { once: true }); }); } };
  try {
    const promises = Array.from({ length: 20 }, (_, i) => controller.readImage(media, `i${i}`, () => true, 'original').then(() => 'ready', error => error.message));
    fail(new Response(null, { status }));
    const outcomes = await Promise.all(promises); assert.ok(outcomes.every(value => value === 'access_denied')); assert.equal(calls, 16);
  } finally { controller.stop(); }
});
