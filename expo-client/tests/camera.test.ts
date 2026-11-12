import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CameraPermissionError, captureWithCamera, isCameraCacheUri } from '../src/cfl/camera-flow';
import { validateDrafts } from '../src/cfl/intake';
import { createFixture } from './fixtures/fixture';
import { uploadImages } from '../src/cfl/uploads';
import { fixtureImageBase64 } from './fixtures/fixture-art';
import { ChatController, type ChatPort, type PendingStore } from '../src/cfl/chat';
import type { ChatView } from '../vendor/contracts/src/index';
import type { AttachmentDraft } from '../src/cfl/drafts';

const asset = { uri: 'synthetic://photo' };
function camera() {
  let launches = 0, discarded = 0, released = 0;
  const body = new Blob([Uint8Array.from(atob(fixtureImageBase64), c => c.charCodeAt(0))], { type: 'image/png' });
  const draft: AttachmentDraft = { id: 'camera-1', kind: 'image', name: 'photo.png', mediaType: body.type, size: body.size, body, uri: asset.uri, width: 40, height: 40, release() { released++; } };
  const port = { async permission() { return { granted: true, canAskAgain: true }; }, async launch() { launches++; return { canceled: false as const, assets: [asset] }; }, draft(_asset: typeof asset) { return draft; }, discard(_asset: typeof asset) { discarded++; } };
  return { port, draft, launches: () => launches, discarded: () => discarded, released: () => released };
}

test('camera denial and cancellation never produce a draft or send', async () => {
  const denied = camera();
  await assert.rejects(captureWithCamera(() => true, { ...denied.port, async permission() { return { granted: false, canAskAgain: false }; } }), (error: unknown) => error instanceof CameraPermissionError && error.code === 'camera_permission_denied' && !error.canAskAgain);
  assert.equal(denied.launches(), 0);
  const canceled = camera();
  assert.equal(await captureWithCamera(() => true, { ...canceled.port, async launch() { return { canceled: true as const, assets: null }; } }), null);
  assert.equal(canceled.discarded(), 0);
});

test('permission and camera completions after session change or disposal are discarded', async () => {
  let current = true, finishPermission!: (p: { granted: boolean; canAskAgain: boolean }) => void;
  const p = camera();
  const pendingPermission = captureWithCamera(() => current, { ...p.port, permission: () => new Promise(resolve => { finishPermission = resolve; }) });
  current = false; finishPermission({ granted: true, canAskAgain: true }); await assert.rejects(pendingPermission, /session_changed/); assert.equal(p.launches(), 0);
  current = true; let finishCamera!: (result: { canceled: false; assets: typeof asset[] }) => void;
  const c = camera();
  const pendingCamera = captureWithCamera<typeof asset, AttachmentDraft>(() => current, { ...c.port, launch: () => new Promise(resolve => { finishCamera = resolve; }) });
  await Promise.resolve(); current = false; finishCamera({ canceled: false, assets: [asset] });
  await assert.rejects(pendingCamera, /session_changed/); assert.equal(c.discarded(), 1);
  const lateDraft = camera(); current = true;
  await assert.rejects(captureWithCamera(() => current, { ...lateDraft.port, draft() { current = false; return lateDraft.draft; } }), /session_changed/);
  assert.equal(lateDraft.released(), 1);
});

test('invalid camera results and failed draft conversion discard only their returned assets', async () => {
  const multiple = camera();
  await assert.rejects(captureWithCamera(() => true, { ...multiple.port, async launch() { return { canceled: false as const, assets: [asset, asset] }; } }), /invalid_photo/);
  assert.equal(multiple.discarded(), 2);
  const broken = camera();
  await assert.rejects(captureWithCamera(() => true, { ...broken.port, draft() { throw Error('file_unavailable'); } }), /file_unavailable/);
  assert.equal(broken.discarded(), 1);
});

test('A to B to A does not revive the original camera session scope', async () => {
  let changed!: (view: ChatView) => void, finish!: (result: { canceled: false; assets: typeof asset[] }) => void;
  const view = (sessionId: string): ChatView => ({ version: 2, sessionId, name: 'fixture', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: null, capabilities: { text: true, steer: true, stop: true, images: false } });
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { throw Error('unused'); }, async lookup() { return null; }, close() {} };
  const store: PendingStore = { async load() { return []; }, async save() {} };
  const controller = new ChatController('fixture', async () => ({ close() {} }) as WebSocket, store, () => 'unused', async (_, fn) => { changed = fn; fn(view('A')); return port; });
  await controller.start(); const scope = controller.scope(), c = camera();
  const result = captureWithCamera<typeof asset, AttachmentDraft>(scope, { ...c.port, launch: () => new Promise(resolve => { finish = resolve; }) });
  await Promise.resolve(); changed(view('B')); changed(view('A')); finish({ canceled: false, assets: [asset] });
  await assert.rejects(result, /session_changed/); assert.equal(c.discarded(), 1); controller.stop();
});

test('camera draft uses the existing capability validation and image submission path', async () => {
  const c = camera(), { controller, media } = createFixture(); await controller.start();
  const drafts = await captureWithCamera(controller.scope(), c.port); assert.ok(drafts);
  const view = controller.snapshot().view!; validateDrafts(view, drafts);
  assert.throws(() => validateDrafts(view, [{ ...drafts[0], mediaType: 'image/heic' }]), /invalid_images/);
  const oversized = { ...drafts[0], body: new Blob([new Uint8Array(8_000_001)], { type: 'image/png' }), size: 8_000_001 };
  assert.throws(() => validateDrafts(view, [oversized]), /invalid_images/);
  const id = await controller.sendPrepared('', async ctx => ({ images: await uploadImages(media, ctx.sessionId, ctx.operationId, drafts, ctx.view.capabilities.images || (() => { throw Error('no images'); })(), ctx.isCurrent, async () => '/9j/2Q==', ctx.signal) }));
  assert.equal(controller.snapshot().view?.messages.find(m => m.operationId === id)?.images?.[0]?.name, 'photo.png');
  drafts[0].release(); assert.equal(c.released(), 1); controller.stop();
});

test('cache cleanup accepts only image-picker UUID files in the local cache', () => {
  const base = 'file:///app/Library/Caches/';
  assert.equal(isCameraCacheUri(base, `${base}ImagePicker/12345678-1234-1234-1234-123456789abc.jpg`), true);
  for (const uri of [`${base}DocumentPicker/12345678-1234-1234-1234-123456789abc.jpg`, `${base}ImagePicker/../other.jpg`, `${base}ImagePicker/%2e%2e%2fother.jpg`, `${base}ImagePicker/12345678-1234-1234-1234-123456789abc.jpg?x=1`, 'https://example.invalid/image.jpg']) assert.equal(isCameraCacheUri(base, uri), false);
});
