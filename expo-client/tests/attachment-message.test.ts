import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFixture } from './fixtures/fixture';
import { validateDrafts } from '../src/cfl/intake';
import type { AttachmentDraft } from '../src/cfl/drafts';
import { attachmentValidationMessage, cameraPhotoMessage } from '../src/ui/attachmentValidationMessage';
import { CameraPhotoError } from '../src/cfl/camera-photo-core';

const view = createFixture().read();
function image(id: string, bytes: number, mediaType = 'image/jpeg'): AttachmentDraft {
  const body = new Blob([new Uint8Array(bytes)], { type: mediaType });
  return { id, kind: 'image', name: 'photo.jpg', mediaType, size: body.size, body, uri: 'fixture:', release() {} };
}
function message(drafts: AttachmentDraft[]) {
  try { validateDrafts(view, drafts); throw new Error('expected rejection'); }
  catch (error) { return attachmentValidationMessage(view, drafts, error); }
}

test('explains the image validation result with readable sizes and supported formats', () => {
  assert.equal(message([image('large', 8_000_001)]), '图片大小约为 8.0 MB，超过当前服务单张上限（约 8.0 MB）。');
  assert.match(message([image('heic', 1, 'image/heic')]), /不支持此图片格式（image\/heic）/);
  assert.match(message([image('empty', 0)]), /图片为空或无法读取/);
  assert.equal(message(Array.from({ length: 7 }, (_, i) => image(`image${i}`, 1))), '最多可选择 6 张图片。');
  assert.equal(message(Array.from({ length: 4 }, (_, i) => image(`image${i}`, 6_000_001))), '图片总大小约为 24.0 MB，超过当前服务总上限（约 24.0 MB）。');
});

test('distinguishes unavailable capability from malformed drafts', () => {
  const draft = image('id', 1);
  const unavailable = { ...view, capabilities: { ...view.capabilities, images: false as const } };
  assert.equal(attachmentValidationMessage(unavailable, [draft], new Error('images_unavailable')), '当前服务暂不支持发送图片。');
  assert.equal(attachmentValidationMessage(view, [draft, draft], new Error('invalid_drafts')), '所选附件超出数量、格式或大小限制。');
});

test('camera preparation explains failure without pretending that a photo was sent', () => {
  assert.equal(cameraPhotoMessage(new CameraPhotoError('camera_image_too_large', 5_242_881, 5_242_880)), '照片压缩后约为 5.2 MB，仍超过可用上限（约 5.2 MB）。');
  assert.match(cameraPhotoMessage(new CameraPhotoError('camera_webp_unsupported')), /不支持 WebP/);
  assert.match(cameraPhotoMessage(new CameraPhotoError('camera_encoding_failed')), /压缩失败/);
  assert.match(cameraPhotoMessage(new CameraPhotoError('camera_image_budget_exhausted')), /总大小上限/);
});
