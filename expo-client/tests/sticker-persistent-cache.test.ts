import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, readdirSync, statSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { StickerClient } from '../src/cfl/stickers';
import type { ApiTransport } from '../src/cfl/transport';
import { FileStickerCache } from '../src/cfl/sticker-cache-store';
import { createStickerCache } from '../src/cfl/sticker-cache';
import { testCacheFiles } from './fixtures/sticker-cache-files';

const version = 'a'.repeat(64);
const page = { stickers: [{ id: 'fixture-sticker', version, name: '测试表情', tags: ['微笑'], mediaType: 'image/webp', available: true }], nextCursor: 'next_page' };

// Test-owned disk adapter; each instance represents a newly constructed app cache.
function disk(directory: string) {
  const path = (key: string) => join(directory, createHash('sha256').update(key).digest('hex'));
  return {
    async get(key: string): Promise<string | null> { try { return readFileSync(path(key), 'utf8'); } catch { return null; } },
    async put(key: string, value: string, current: () => boolean): Promise<void> { if (current()) writeFileSync(path(key), value); },
  };
}

test('new StickerClient restores an observed page and thumbnail without waiting for network', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'etos-sticker-cache-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  let blocked = false, calls = 0;
  const transport: ApiTransport = {
    origin: 'https://fixture.invalid', async read() { throw Error('unused'); },
    async request(path) {
      calls++;
      if (blocked) return new Promise<Response>(() => {});
      if (path.startsWith('/api/stickers/media/')) return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/webp' } });
      return new Response(JSON.stringify(page), { headers: { 'content-type': 'application/json' } });
    },
  };
  const first = new (StickerClient as any)(transport, 'fixture-session', () => true, undefined, disk(directory));
  assert.deepEqual(await first.page('favorites'), page);
  assert.deepEqual((await first.media(version)).bytes, new Uint8Array([1, 2, 3]));
  blocked = true;
  const reopened = new (StickerClient as any)(transport, 'fixture-session', () => true, undefined, disk(directory));
  assert.deepEqual(await reopened.cachedPage('favorites'), page);
  assert.deepEqual((await reopened.cachedMedia(version)).bytes, new Uint8Array([1, 2, 3]));
  assert.equal(calls, 2);
});

function fixtureTransport() {
  let status = 200;
  let calls = 0;
  const transport: ApiTransport = {
    origin: 'https://fixture.invalid', async read() { throw Error('unused'); },
    async request(path) {
      calls++;
      if (status !== 200) return new Response(null, { status });
      if (path.startsWith('/api/stickers/media/')) return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/webp' } });
      return new Response(JSON.stringify(page), { headers: { 'content-type': 'application/json' } });
    },
  };
  return { transport, setStatus: (value: number) => { status = value; }, calls: () => calls };
}
function temporaryDirectory(t: { after(fn: () => void): void }) {
  const directory = mkdtempSync(join(tmpdir(), 'etos-sticker-cache-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test('real client and bounded file cache restore in a separate process without network', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const { transport } = fixtureTransport();
  const client = new StickerClient(transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await client.media(version); await cache.flush();
  const child = spawnSync(process.execPath, ['--import', 'tsx', 'tests/fixtures/sticker-cache-child.ts', directory], {
    cwd: process.cwd(), encoding: 'utf8', env: { ...process.env, HOME: directory, XDG_CACHE_HOME: directory, TMPDIR: directory },
  });
  assert.equal(child.status, 0, child.stderr);
  assert.match(child.stdout, /restored cached page and thumbnail without network/);
});

test('snapshot keys preserve origin, session, cursor, limit, and resource variant', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const { transport, calls } = fixtureTransport();
  const client = new StickerClient(transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await client.media(version); await cache.flush();
  const same = new StickerClient(transport, 'fixture-session', () => true, undefined, cache);
  assert.deepEqual(await same.cachedPage('favorites'), page);
  assert.equal(await same.cachedPage('favorites', { cursor: 'next_page' }), null);
  assert.equal(await same.cachedPage('favorites', { limit: 1 }), null);
  assert.equal(await same.cachedPage('packs'), null);
  assert.equal(await same.cachedPage('search', { query: 'x' }), null);
  assert.equal(await same.cachedMedia('b'.repeat(64)), null);
  assert.equal(await new StickerClient(transport, 'another-session', () => true, undefined, cache).cachedPage('favorites'), null);
  assert.equal(await new StickerClient({ ...transport, origin: 'https://other.invalid' }, 'fixture-session', () => true, undefined, cache).cachedMedia(version), null);
  assert.equal(calls(), 2);
  assert.ok(readdirSync(directory).every(name => /^[a-f0-9]{64}$/.test(name)));
});

test('denied refresh disables cached reads on that client; re-login preserves the files', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const fixture = fixtureTransport(), client = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await client.media(version); await cache.flush();
  fixture.setStatus(401);
  await assert.rejects(client.page('favorites'), /access_denied/);
  await assert.rejects(client.cachedPage('favorites'), /access_denied/);
  await assert.rejects(client.cachedMedia(version), /access_denied/);
  fixture.setStatus(403);
  const fresh = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  await assert.rejects(fresh.media(version), /access_denied/);
  await assert.rejects(fresh.cachedMedia(version), /access_denied/);
  const reauthorized = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  assert.deepEqual(await reauthorized.cachedPage('favorites'), page);
});

test('corrupt records and storage failures are misses and do not block network', async t => {
  const directory = temporaryDirectory(t), files = testCacheFiles(directory), cache = new FileStickerCache(files);
  const fixture = fixtureTransport(), client = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await cache.flush();
  const [name] = readdirSync(directory);
  writeFileSync(join(directory, name), '{"value":"wrong","digest":"' + '0'.repeat(64) + '"}');
  assert.equal(await client.cachedPage('favorites'), null);
  const broken = new FileStickerCache({ ...files, async list() { throw Error('disk unavailable'); } });
  const fallback = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, broken);
  assert.equal(await fallback.cachedPage('favorites'), null);
  assert.deepEqual(await fallback.page('favorites'), page);
  await broken.flush();
});

test('file budget evicts oldest written records and limits count', async t => {
  const directory = temporaryDirectory(t), files = testCacheFiles(directory), cache = new FileStickerCache(files, 1000, 2);
  await cache.put('first', 'a'.repeat(100), () => true);
  utimesSync(join(directory, readdirSync(directory)[0]), new Date(1000), new Date(1000));
  await cache.put('second', 'b'.repeat(100), () => true);
  assert.equal(await cache.get('first'), 'a'.repeat(100));
  await cache.put('third', 'c'.repeat(100), () => true);
  assert.equal(await cache.get('first'), null);
  assert.equal(await cache.get('second'), 'b'.repeat(100));
  assert.equal(await cache.get('third'), 'c'.repeat(100));
  assert.equal(readdirSync(directory).length, 2);
  assert.ok(readdirSync(directory).reduce((total, name) => total + statSync(join(directory, name)).size, 0) <= 1000);
});

test('default budget retains more than 64 MiB and evicts oldest beyond 256 MiB', async t => {
  const directory = temporaryDirectory(t), base = testCacheFiles(directory);
  const oldest = 'f'.repeat(64), newer = 'e'.repeat(64);
  const virtual = new Map([[oldest, { name: oldest, size: 70 * 1024 * 1024, modified: 1 }]]);
  const files = {
    ...base,
    async list() { return [...virtual.values(), ...await base.list()]; },
    remove(name: string) { if (!virtual.delete(name)) base.remove(name); },
  };
  const cache = new FileStickerCache(files);
  await cache.put('first', 'small record', () => true);
  assert.ok(virtual.has(oldest), '70 MiB of existing cache must fit the default budget');
  virtual.set(newer, { name: newer, size: 190 * 1024 * 1024, modified: 2 });
  await cache.put('second', 'small record', () => true);
  assert.equal(virtual.has(oldest), false);
  assert.equal(virtual.has(newer), true);
  assert.equal(await cache.get('second'), 'small record');
});

test('cancelled delayed write never commits a cache file', async t => {
  const directory = temporaryDirectory(t), base = testCacheFiles(directory);
  let release!: () => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const cache = new FileStickerCache({ ...base, async write(name, value) { await base.write(name, value); started(); await gate; } });
  let current = true;
  const pending = cache.put('key', 'value', () => current);
  await began; current = false; release(); await pending;
  assert.equal(await cache.get('key'), null);
  assert.deepEqual(readdirSync(directory), []);
});

test('pages are cached independently and invalid network responses do not replace valid snapshots', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  let invalid = false;
  const firstPage = { stickers: [], nextCursor: 'cursor1' };
  const secondPage = { stickers: [], nextCursor: null };
  const transport: ApiTransport = {
    origin: 'https://fixture.invalid', async read() { throw Error('unused'); },
    async request(path) {
      if (invalid) return new Response(JSON.stringify({ stickers: 'invalid', nextCursor: null }));
      return new Response(JSON.stringify(path.includes('cursor=cursor1') ? secondPage : firstPage));
    },
  };
  const client = new StickerClient(transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await cache.flush();
  assert.equal(await client.cachedPage('favorites', { cursor: 'cursor1' }), null);
  await client.page('favorites', { cursor: 'cursor1' }); await cache.flush();
  assert.deepEqual(await client.cachedPage('favorites'), firstPage);
  assert.deepEqual(await client.cachedPage('favorites', { cursor: 'cursor1' }), secondPage);
  invalid = true;
  await assert.rejects(client.page('favorites')); await cache.flush();
  assert.deepEqual(await client.cachedPage('favorites'), firstPage);
});

test('scope change and abort reject late cache reads', async () => {
  let current = true, release!: (value: string | null) => void;
  const store = { get: async () => new Promise<string | null>(resolve => { release = resolve; }), async put() {} };
  const { transport } = fixtureTransport();
  const client = new StickerClient(transport, 'fixture-session', () => current, undefined, store);
  const pending = client.cachedPage('favorites');
  current = false; release(JSON.stringify(page));
  await assert.rejects(pending, /session_changed/);
  const abort = new AbortController(); current = true;
  const aborted = new StickerClient(transport, 'fixture-session', () => true, abort.signal, store).cachedPage('favorites');
  abort.abort(); release(JSON.stringify(page));
  await assert.rejects(aborted, { name: 'AbortError' });
});

test('oversize cache entries and write failure cannot interrupt successful media requests', async t => {
  const directory = temporaryDirectory(t), base = testCacheFiles(directory);
  const cache = new FileStickerCache({ ...base, async write() { throw Error('disk full'); } });
  const { transport } = fixtureTransport();
  const client = new StickerClient(transport, 'fixture-session', () => true, undefined, cache);
  assert.deepEqual((await client.media(version))?.bytes, new Uint8Array([1, 2, 3]));
  await cache.flush();
  assert.equal(await client.cachedMedia(version), null);
  const tiny = new FileStickerCache(base, 40, 5);
  await tiny.put('large', 'x'.repeat(100), () => true);
  assert.equal(await tiny.get('large'), null);
  assert.deepEqual(readdirSync(directory), []);
});

test('confirmed thumbnail 404 removes only its own cached version', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const fixture = fixtureTransport(), client = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  await client.media(version); await client.media('b'.repeat(64)); await cache.flush();
  fixture.setStatus(404);
  assert.equal(await client.media(version), null); await cache.flush();
  assert.equal(await client.cachedMedia(version), null);
  assert.ok(await client.cachedMedia('b'.repeat(64)));
});

test('web cache factory safely returns no file store', () => {
  assert.equal(createStickerCache(), undefined);
});

test('network failure retains snapshots but denial during a pending read blocks delivery', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const fixture = fixtureTransport(), client = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  await client.page('favorites'); await cache.flush();
  fixture.setStatus(503);
  await assert.rejects(client.page('favorites'), /sticker_unavailable/);
  assert.deepEqual(await client.cachedPage('favorites'), page);
  let release!: (value: string | null) => void;
  const delayed = { get: async () => new Promise<string | null>(resolve => { release = resolve; }), async put() {} };
  const pendingClient = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, delayed);
  const pending = pendingClient.cachedPage('favorites');
  fixture.setStatus(401);
  await assert.rejects(pendingClient.page('favorites'), /access_denied/);
  release(JSON.stringify(page));
  await assert.rejects(pending, /access_denied/);
});

test('cache serialization failure leaves successful network media available', async t => {
  const directory = temporaryDirectory(t), cache = new FileStickerCache(testCacheFiles(directory));
  const fixture = fixtureTransport();
  t.mock.method(globalThis, 'btoa', () => { throw Error('encoding unavailable'); });
  const client = new StickerClient(fixture.transport, 'fixture-session', () => true, undefined, cache);
  assert.deepEqual((await client.media(version))?.bytes, new Uint8Array([1, 2, 3]));
  await cache.flush();
  assert.deepEqual(readdirSync(directory), []);
});
