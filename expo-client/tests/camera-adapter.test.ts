import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { createFixture } from './fixtures/fixture';
import type { AttachmentDraft } from '../src/cfl/drafts';

test('native adapter requests one unresized quality-0.8 WebP and deletes only its output', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'etos-camera-adapter-'));
  const mock = {
    'expo-image-manipulator': `
      export const SaveFormat = {WEBP:'webp'};
      export const ImageManipulator = {manipulate(uri) {
        const s=globalThis.__cameraAdapter; s.input=uri; s.manipulates++;
        return {async renderAsync(){s.renders++; return {async saveAsync(options){s.options=options; s.saves++; return {uri:s.output,width:2,height:2}},release(){s.imageReleased++}}},release(){s.contextReleased++}};
      }};`,
    'expo-file-system': `
      export const Paths={cache:{uri:'file:///fixture/'}};
      export class File extends Blob { constructor(uri){super([globalThis.__cameraAdapter.bytes],{type:'image/webp'});this.uri=uri} delete(){globalThis.__cameraAdapter.deleted.push(this.uri)} }`,
  };
  try {
    await build({ entryPoints: ['src/cfl/camera-photo.ts'], outfile: join(tmp, 'adapter.cjs'), bundle: true, platform: 'node', format: 'cjs', logLevel: 'silent', plugins: [{ name: 'test-owned-native', setup(builder) {
      builder.onResolve({ filter: /^(expo-image-manipulator|expo-file-system)$/ }, args => ({ path: args.path, namespace: 'fake' }));
      builder.onLoad({ filter: /.*/, namespace: 'fake' }, args => ({ contents: mock[args.path as keyof typeof mock], loader: 'js' }));
    } }] });
    const prepare = createRequire(import.meta.url)(join(tmp, 'adapter.cjs')).prepareCameraPhoto as typeof import('../src/cfl/camera-photo').prepareCameraPhoto;
    const bytes = Uint8Array.from(atob('UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA='), c => c.charCodeAt(0));
    const state = { bytes, output: 'file:///fixture/ImageManipulator/12345678-1234-1234-1234-123456789abc.webp', input: '', options: {} as object, manipulates: 0, renders: 0, saves: 0, imageReleased: 0, contextReleased: 0, deleted: [] as string[] };
    (globalThis as typeof globalThis & { __cameraAdapter?: typeof state }).__cameraAdapter = state;
    let sourceReleases = 0;
    const body = new Blob([new Uint8Array(6_000_000)], { type: 'image/jpeg' });
    const photo: AttachmentDraft = { id: 'camera-1', kind: 'image', name: 'photo.jpg', mediaType: 'image/jpeg', size: body.size, body, uri: 'file:///fixture/ImagePicker/camera.jpg', width: 2, height: 2, release() { sourceReleases++; } };
    const { controller } = createFixture(); await controller.start();
    try {
      const view = controller.snapshot().view!; assert.ok(view.capabilities.images); view.capabilities.images = { ...view.capabilities.images, maxImageBytes: 5_200_000 };
      const result = await prepare(view, [], photo, controller.scope());
      assert.equal(state.input, photo.uri); assert.deepEqual(state.options, { format: 'webp', compress: 0.8 });
      assert.equal(state.manipulates, 1); assert.equal(state.renders, 1); assert.equal(state.saves, 1);
      assert.equal(state.imageReleased, 1); assert.equal(state.contextReleased, 1); assert.equal(sourceReleases, 1);
      assert.deepEqual(state.deleted, []); result.release(); result.release(); assert.deepEqual(state.deleted, [state.output]);
      state.deleted.length = 0;
      state.output = 'file:///fixture/ImageManipulator/not-owned.webp';
      const invalid = { ...photo, id: 'camera-2' };
      await assert.rejects(prepare(view, [], invalid, controller.scope()), /camera_encoding_failed/);
      assert.equal(sourceReleases, 2); assert.deepEqual(state.deleted, [], 'do not delete an unrecognized path');
      const protectedUri = 'file:///fixture/ImageManipulator/87654321-4321-4321-4321-cba987654321.webp';
      state.output = protectedUri;
      const existing = { ...photo, id: 'existing', size: bytes.length, body: new Blob([bytes], { type: 'image/webp' }), mediaType: 'image/webp', uri: protectedUri };
      await assert.rejects(prepare(view, [existing], { ...photo, id: 'camera-3' }, controller.scope()), /camera_encoding_failed/);
      assert.equal(sourceReleases, 3); assert.deepEqual(state.deleted, [], 'never delete an existing draft');
    } finally { controller.stop(); }
  } finally {
    delete (globalThis as typeof globalThis & { __cameraAdapter?: unknown }).__cameraAdapter;
    rmSync(tmp, { recursive: true, force: true });
  }
});
