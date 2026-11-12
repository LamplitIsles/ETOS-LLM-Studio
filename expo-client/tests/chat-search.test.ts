import { test } from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { createFixture } from './fixtures/fixture';
import { startFixtureSeedHost } from './fixtures/seed-host';
import type { ChatView, SearchResult, SearchReadResult } from '../vendor/contracts/src/index';

const result = (id: string): SearchResult => ({ hits: [{ id, kind: 'message', sessionId: 'archive-other', snippet: { segments: [{ text: 'synthetic', highlighted: true }] } }], estimatedTotalHits: 1, limited: false });
const read = (id: string): SearchReadResult => ({ record: { id, kind: 'message', sessionId: 'archive-other', content: 'synthetic' }, context: { targetSourceRecordIndex: 2, truncated: false, items: [{ sourceRecordIndex: 2, kind: 'message', content: 'synthetic' }] } });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
async function setup(port: ChatPort) {
  const fixture = createFixture(); const initial = fixture.read(); let change = (_: ChatView) => {}; let offline = (_: Error) => {};
  const controller = new ChatController('fixture://local', async () => ({ close() {} }) as globalThis.WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, changed, disconnected) => { change = changed; offline = disconnected; changed(initial); return port; });
  await controller.start(); return { controller, initial, change: (v: ChatView) => change(v), offline: (error: Error) => offline(error) };
}

test('real WebSocket search and read use fixture archive and return context without switching session', async () => {
  const host = await startFixtureSeedHost();
  const controller = new ChatController('fixture://local', async () => new WebSocket(`ws://127.0.0.1:${host.controlPort}/api/chat/socket`) as unknown as globalThis.WebSocket, { async load() { return []; }, async save() {} }, () => 'unused');
  try {
    await controller.start(); const found = await controller.search('  周末  '); assert.ok(found.hits.some(hit => hit.id === 'fixture-older'));
    const context = await controller.searchRead('fixture-older'); assert.match(context.record.content, /周末/); assert.ok(context.context.items.some(item => item.sourceRecordIndex === context.context.targetSourceRecordIndex));
    assert.equal(controller.snapshot().view?.sessionId, 'fixture-session');
  } finally { controller.stop(); await host.close(); }
});

test('newer search/read supersedes older results and new search supersedes reads', async () => {
  const fixture = createFixture(); const searches = [deferred<SearchResult>(), deferred<SearchResult>()], reads = [deferred<SearchReadResult>(), deferred<SearchReadResult>()]; let si = 0, ri = 0;
  const { controller } = await setup({ ...fixture.port, search: () => searches[si++].promise, searchRead: () => reads[ri++].promise });
  try {
    const a = controller.search('first'), b = controller.search('second'); searches[1].resolve(result('b')); assert.equal((await b).hits[0].id, 'b'); searches[0].resolve(result('a')); await assert.rejects(a, /search_superseded/);
    const c = controller.searchRead('a'), d = controller.searchRead('b'); reads[1].resolve(read('b')); assert.equal((await d).record.id, 'b'); reads[0].resolve(read('a')); await assert.rejects(c, /search_superseded/);
  } finally { controller.stop(); }
});

test('session A→B→A, stop and disconnect reject late responses', async () => {
  const fixture = createFixture(), one = deferred<SearchResult>(), two = deferred<SearchResult>(), three = deferred<SearchResult>(); let index = 0;
  const { controller, initial, change, offline } = await setup({ ...fixture.port, search: () => [one, two, three][index++].promise });
  try {
    const a = controller.search('a'); change({ ...initial, sessionId: 'B' }); change(initial); one.resolve(result('a')); await assert.rejects(a, /session_changed/);
    const b = controller.search('b'); offline(Error('offline')); two.resolve(result('b')); await assert.rejects(b, /offline/);
    controller.stop(); await controller.start(); const c = controller.search('c'); controller.stop(); three.resolve(result('c')); await assert.rejects(c, /session_changed/);
  } finally { controller.stop(); }
});

test('search enforces shared input, output identity and context bounds even for an injected port', async () => {
  const fixture = createFixture(); let calls = 0;
  const { controller } = await setup({ ...fixture.port, async search() { calls++; return { ...result('a'), hits: [...result('a').hits, ...result('a').hits] }; }, async searchRead() { return read('wrong'); } });
  try {
    await assert.rejects(controller.search(' ')); await assert.rejects(controller.search('a'.repeat(501))); assert.equal(calls, 0);
    await assert.rejects(controller.search('a'), /Duplicate/); await assert.rejects(controller.searchRead('expected'), /Invalid search context/);
    await assert.rejects(controller.searchRead('')); await assert.rejects(controller.searchRead('x'.repeat(301)));
  } finally { controller.stop(); }
});

test('new search or explicit close invalidates outstanding context without changing server state', async () => {
  const fixture = createFixture(), first = deferred<SearchReadResult>(), second = deferred<SearchReadResult>(); let i = 0;
  const { controller } = await setup({ ...fixture.port, search: async () => result('new'), searchRead: () => [first, second][i++].promise });
  try {
    const a = controller.searchRead('a'); await controller.search('new'); first.resolve(read('a')); await assert.rejects(a, /search_superseded/);
    const b = controller.searchRead('b'); controller.cancelSearch(); second.resolve(read('b')); await assert.rejects(b, /search_superseded/);
  } finally { controller.stop(); }
});

test('search and context responses enforce result count and context length', async () => {
  const fixture = createFixture();
  const { controller } = await setup({ ...fixture.port, async search() { return { hits: Array.from({ length: 21 }, (_, i) => ({ ...result('a').hits[0], id: `${i}` })), estimatedTotalHits: 21, limited: true }; }, async searchRead({ id }) { const output = read(id); output.context.items[0].content = '文'.repeat(12001); return output; } });
  try { await assert.rejects(controller.search('x')); await assert.rejects(controller.searchRead('a'), /Invalid search context/); }
  finally { controller.stop(); }
});
