import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findArchiveWorkspaceImages } from '../src/cfl/archive-workspace-images';
import { loadMarkdownImage } from '../src/cfl/markdown-image';
import type { ApiTransport } from '../src/cfl/transport';

const marker = (path: string, n = 1) => `<image name=[Image #${n}] path="${path}"></image>`;
const opts = { workspaceImages: true, isCurrent: () => true };

test('finds literal workspace image references without changing mixed Markdown', () => {
  const image = marker('/synthetic/workspace/.lamplit/attachments/a%20 b.model.jpg');
  const source = `你好 **加粗** ${image} 后面 [链接](https://example.invalid/)`;
  const result = findArchiveWorkspaceImages(source, opts);
  assert.equal(result.status, 'ok');
  assert.equal(result.images.length, 1);
  const ref = result.images[0]!;
  assert.equal(source.slice(ref.start, ref.end), image);
  assert.equal(ref.path, '/synthetic/workspace/.lamplit/attachments/a%20 b.model.jpg');
  assert.equal(ref.requestPath, `/api/chat/workspace-image?path=${encodeURIComponent(ref.path)}`);
});

test('does not interpret code, unknown HTML, links, escapes or malformed tags', () => {
  const image = marker('/synthetic/workspace/image.png');
  const cases = [
    `\`${image}\``, `\`\`\`html\n${image}\n\`\`\``, `~~~html\n${image}\n~~~`, `    ${image}\n`,
    `\`example\` ${image}`, `> ${image}`, `- ${image}`, `# ${image}`,
    `<div>${image}</div>`, `<span>${image}</span>`, `[${image}](https://example.invalid)`,
    `\\${image}`, `![x](${image})`, image.replace('path=', 'src='),
    image.replace('image>', 'image x>'), marker('/synthetic/workspace/a"b.png'),
    marker('/synthetic/workspace/a<foo>.png'),
  ];
  for (const source of cases) assert.equal(findArchiveWorkspaceImages(source, opts).images.length, 0, source);
});

test('paths, capabilities, size and cancellation fail closed', () => {
  for (const path of ['../secret.png', '/tmp/../secret.png', '//host/a.png', 'https://evil.invalid/a.png', '/api/auth/status.png', '/ok/a.svg', '/ok/\u0000a.png']) {
    assert.equal(findArchiveWorkspaceImages(marker(path), opts).images.length, 0, path);
  }
  assert.equal(findArchiveWorkspaceImages(marker('/ok/a.png'), { ...opts, workspaceImages: false }).images.length, 0);
  assert.equal(findArchiveWorkspaceImages(`first\r\n\r\n${marker('/ok/a.png')}`, opts).status, 'unsupported');
  assert.equal(findArchiveWorkspaceImages('x'.repeat(131073) + marker('/ok/a.png'), opts).status, 'limit');
  assert.equal(findArchiveWorkspaceImages(Array.from({ length: 17 }, (_, i) => marker(`/ok/${i}.png`, i + 1)).join(' '), opts).status, 'limit');
  const abort = new AbortController(); abort.abort();
  assert.throws(() => findArchiveWorkspaceImages(marker('/ok/a.png'), { ...opts, signal: abort.signal }), { name: 'AbortError' });
  assert.throws(() => findArchiveWorkspaceImages(marker('/ok/a.png'), { ...opts, isCurrent: () => false }), /session_changed/);
});

test('recognized literal reference uses the existing authenticated bounded image loader', async () => {
  const source = marker('/synthetic/100%20 test.png');
  const ref = findArchiveWorkspaceImages(source, opts).images[0]!;
  const calls: Array<{ path: string; init?: RequestInit }> = [];
  let response = () => new Response(new Uint8Array([1, 2, 3]), { headers: { 'Content-Type': 'image/png' } });
  const transport: ApiTransport = {
    origin: 'https://fixture.invalid',
    async read() { throw new Error('unexpected read'); },
    async request(path, init) { calls.push({ path, init }); return response(); },
  };
  assert.equal((await loadMarkdownImage(ref.requestPath, transport, opts)).contentType, 'image/png');
  assert.equal(calls[0]?.path, `/api/chat/workspace-image?path=${encodeURIComponent('/synthetic/100%20 test.png')}`);
  assert.equal(calls[0]?.init?.method, 'GET');
  response = () => new Response(null, { status: 403 });
  await assert.rejects(loadMarkdownImage(ref.requestPath, transport, opts), /access_denied/);
  response = () => new Response(null, { status: 404 });
  await assert.rejects(loadMarkdownImage(ref.requestPath, transport, opts), /missing/);
  response = () => new Response(new Uint8Array([1]), { headers: { 'Content-Type': 'image/svg+xml' } });
  await assert.rejects(loadMarkdownImage(ref.requestPath, transport, opts), /invalid_media/);
  await assert.rejects(loadMarkdownImage(ref.requestPath, transport, { ...opts, workspaceImages: false }), /invalid_media/);
});

test('preserves ordering and UTF-16 offsets without parsing formatted or code content', () => {
  const a = marker('/synthetic/一.png');
  const b = marker('/synthetic/two.gif', 2);
  const source = `👨‍👩‍👧‍👦 ${a} 文本 ${b}\n\n**${a}**\n\n\`example ${b}\``;
  const result = findArchiveWorkspaceImages(source, opts);
  assert.equal(result.status, 'ok');
  assert.deepEqual(result.images.map(ref => source.slice(ref.start, ref.end)), [a, b]);
  assert.deepEqual(result.images.map(ref => ref.path), ['/synthetic/一.png', '/synthetic/two.gif']);
});
