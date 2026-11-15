import assert from 'node:assert/strict';
import { StickerClient } from '../../src/cfl/stickers';
import { FileStickerCache } from '../../src/cfl/sticker-cache-store';
import { testCacheFiles } from './sticker-cache-files';

const directory = process.argv[2];
const transport = { origin: 'https://fixture.invalid', async read(): Promise<Response> { throw Error('unexpected network'); }, async request(): Promise<Response> { throw Error('unexpected network'); } };
const client = new StickerClient(transport, 'fixture-session', () => true, undefined, new FileStickerCache(testCacheFiles(directory)));
assert.deepEqual(await client.cachedPage('favorites'), { stickers: [{ id: 'fixture-sticker', version: 'a'.repeat(64), name: '测试表情', tags: ['微笑'], mediaType: 'image/webp', available: true }], nextCursor: 'next_page' });
assert.deepEqual((await client.cachedMedia('a'.repeat(64)))?.bytes, new Uint8Array([1, 2, 3]));
console.log('child restored cached page and thumbnail without network');
