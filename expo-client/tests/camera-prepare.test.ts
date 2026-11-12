import { test } from 'node:test';
import assert from 'node:assert/strict';
import { captureWithCamera } from '../src/cfl/camera-flow';
import { CameraPhotoError, isCameraWebpCacheUri, prepareCameraPhotoCore, type CameraEncodedPhoto } from '../src/cfl/camera-photo-core';
import { validateDrafts } from '../src/cfl/intake';
import { createFixture } from './fixtures/fixture';
import { uploadImages } from '../src/cfl/uploads';
import type { AttachmentDraft } from '../src/cfl/drafts';

const webp = Uint8Array.from(atob('UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA='), c => c.charCodeAt(0));
function source(size = 6_000_000) {
  let released = 0;
  const body = new Blob([new Uint8Array(size)], { type: 'image/jpeg' });
  const photo: AttachmentDraft = { id: 'camera-1', kind: 'image', name: 'photo.jpg', mediaType: 'image/jpeg', size: body.size, body, uri: 'fixture://camera', width: 2, height: 2, release() { released++; } };
  return { photo, released: () => released };
}
function encoded(): CameraEncodedPhoto {
  return { uri: 'fixture://encoded.webp', body: new Blob([webp], { type: 'image/webp' }), width: 2, height: 2, release() {} };
}

test('camera to validation accepts one oversized photo after exactly one WebP encoding', async () => {
  const { controller, media } = createFixture(); await controller.start();
  try {
    const view = controller.snapshot().view!;
    assert.ok(view.capabilities.images);
    view.capabilities.images = { ...view.capabilities.images, maxImageBytes: 5_200_000 };
    const original = source(); let calls = 0;
    const selected = await captureWithCamera(controller.scope(), { async permission() { return { granted: true, canAskAgain: true }; }, async launch() { return { canceled: false as const, assets: [original.photo] }; }, draft(photo) { return photo; }, discard(photo) { photo.release(); } });
    assert.ok(selected);
    assert.throws(() => validateDrafts(view, selected), /invalid_images/, 'original pre-fix caller rejects before preview');
    const result = await prepareCameraPhotoCore(view, [], selected[0], controller.scope(), async () => { calls++; return encoded(); });
    assert.equal(calls, 1); assert.equal(result.mediaType, 'image/webp'); assert.equal(result.name, 'photo.webp');
    validateDrafts(view, [result]); assert.equal(original.released(), 1);
    const id = await controller.sendPrepared('', async ctx => { assert.ok(ctx.view.capabilities.images); return { images: await uploadImages(media, ctx.sessionId, ctx.operationId, [result], ctx.view.capabilities.images, ctx.isCurrent, async () => '/9j/2Q==', ctx.signal) }; });
    assert.equal(controller.snapshot().view?.messages.find(message => message.operationId === id)?.images?.[0]?.name, 'photo.webp');
    result.release();
  } finally { controller.stop(); }
});

test('compliant photo is returned unchanged and is owned by the caller', async () => {
  const { controller } = createFixture(); await controller.start();
  try {
    const original = source(32); let calls = 0;
    const result = await prepareCameraPhotoCore(controller.snapshot().view!, [], original.photo, controller.scope(), async () => { calls++; return encoded(); });
    assert.equal(result, original.photo); assert.equal(calls, 0); assert.equal(original.released(), 0);
    result.release(); assert.equal(original.released(), 1);
  } finally { controller.stop(); }
});

test('capability, count, remaining budget and WebP support fail before encoding without touching old drafts', async () => {
  const { controller } = createFixture(); await controller.start();
  try {
    const base = controller.snapshot().view!; const limits = base.capabilities.images; assert.ok(limits);
    const old = source(32); old.photo.id = 'old';
    const cases = [
      { view: { ...base, capabilities: { ...base.capabilities, images: false as const } }, existing: [], expected: 'images_unavailable' },
      { view: { ...base, capabilities: { ...base.capabilities, images: { ...limits, maxImagesPerMessage: 1 } } }, existing: [old.photo], expected: 'camera_image_count_limit' },
      { view: { ...base, capabilities: { ...base.capabilities, images: { ...limits, maxMessageImageBytes: 32 } } }, existing: [old.photo], expected: 'camera_image_budget_exhausted' },
      { view: { ...base, capabilities: { ...base.capabilities, images: { ...limits, maxImageBytes: 100, mediaTypes: ['image/jpeg'] as ('image/jpeg')[] } } }, existing: [], expected: 'camera_webp_unsupported' },
    ];
    for (const item of cases) {
      const original = source(); let calls = 0;
      await assert.rejects(prepareCameraPhotoCore(item.view, item.existing, original.photo, controller.scope(), async () => { calls++; return encoded(); }), { message: item.expected });
      assert.equal(calls, 0); assert.equal(original.released(), 1); assert.equal(old.released(), 0);
    }
  } finally { controller.stop(); }
});

test('too-large encoded output reports exact remaining limit and releases both resources', async () => {
  const { controller } = createFixture(); await controller.start();
  try {
    const base = controller.snapshot().view!, old = source(32), original = source(); old.photo.id = 'old';
    const limits = base.capabilities.images; assert.ok(limits);
    const view = { ...base, capabilities: { ...base.capabilities, images: { ...limits, maxImageBytes: 100, maxMessageImageBytes: 80 } } };
    let released = 0; const output = encoded(); output.release = () => { released++; };
    await assert.rejects(prepareCameraPhotoCore(view, [old.photo], original.photo, controller.scope(), async () => output), (error: unknown) => error instanceof CameraPhotoError && error.code === 'camera_image_too_large' && error.actualBytes === output.body.size && error.maxBytes === 48);
    assert.equal(original.released(), 1); assert.equal(released, 1); assert.equal(old.released(), 0);
  } finally { controller.stop(); }
});

test('encoding failure, invalid bytes/type/dimensions and late results are discarded', async () => {
  const { controller } = createFixture(); await controller.start();
  try {
    const base = controller.snapshot().view!, limits = base.capabilities.images; assert.ok(limits);
    const view = { ...base, capabilities: { ...base.capabilities, images: { ...limits, maxImageBytes: 100 } } };
    for (const invalid of ['throws', 'bytes', 'mime', 'dimensions'] as const) {
      const original = source(); let released = 0; const output = encoded(); output.release = () => { released++; };
      if (invalid === 'bytes') output.body = new Blob([new Uint8Array(20)], { type: 'image/webp' });
      if (invalid === 'mime') output.body = new Blob([webp], { type: 'image/jpeg' });
      if (invalid === 'dimensions') output.width = 1;
      await assert.rejects(prepareCameraPhotoCore(view, [], original.photo, controller.scope(), async () => { if (invalid === 'throws') throw Error('codec'); return output; }), { message: 'camera_encoding_failed' });
      assert.equal(original.released(), 1); assert.equal(released, invalid === 'throws' ? 0 : 1);
    }
    let current = true, finish!: (value: CameraEncodedPhoto) => void, released = 0;
    const original = source(), output = encoded(); output.release = () => { released++; };
    const pending = prepareCameraPhotoCore(view, [], original.photo, () => current, () => new Promise(resolve => { finish = resolve; }));
    current = false; finish(output); await assert.rejects(pending, /session_changed/);
    assert.equal(original.released(), 1); assert.equal(released, 1);
    const alreadyStale = source(); let calls = 0;
    await assert.rejects(prepareCameraPhotoCore(view, [], alreadyStale.photo, () => false, async () => { calls++; return encoded(); }), /session_changed/);
    assert.equal(calls, 0); assert.equal(alreadyStale.released(), 1);
    let generation = 1, finishRead!: (value: ArrayBuffer) => void, reading!: () => void, readReleased = 0;
    const started = new Promise<void>(resolve => { reading = resolve; });
    const afterRead = source(), pendingOutput = encoded(); pendingOutput.release = () => { readReleased++; };
    Object.defineProperty(pendingOutput.body, 'arrayBuffer', { value: () => { reading(); return new Promise<ArrayBuffer>(resolve => { finishRead = resolve; }); } });
    const pendingRead = prepareCameraPhotoCore(view, [], afterRead.photo, () => generation === 1, async () => pendingOutput);
    await started; generation = 3; finishRead(webp.slice().buffer); await assert.rejects(pendingRead, /session_changed/);
    assert.equal(afterRead.released(), 1); assert.equal(readReleased, 1);
  } finally { controller.stop(); }
});

test('only UUID WebP files in the ImageManipulator cache are eligible for deletion', () => {
  const root = 'file:///app/Library/Caches/';
  assert.equal(isCameraWebpCacheUri(root, `${root}ImageManipulator/12345678-1234-1234-1234-123456789abc.webp`), true);
  for (const uri of [`${root}ImagePicker/12345678-1234-1234-1234-123456789abc.webp`, `${root}ImageManipulator/../other.webp`, `${root}ImageManipulator/12345678-1234-1234-1234-123456789abc.jpg`, `${root}ImageManipulator/12345678-1234-1234-1234-123456789abc.webp?x=1`, 'https://example.invalid/x.webp']) assert.equal(isCameraWebpCacheUri(root, uri), false);
});
