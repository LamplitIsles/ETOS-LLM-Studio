import type { ChatView } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from './drafts';
import { validateDrafts } from './intake';

export type CameraEncodedPhoto = { uri: string; body: Blob; width: number; height: number; release(): void };
export type CameraPhotoErrorCode = 'images_unavailable' | 'camera_image_count_limit' | 'camera_image_budget_exhausted' | 'camera_webp_unsupported' | 'camera_image_too_large' | 'camera_encoding_failed';
export class CameraPhotoError extends Error {
  constructor(readonly code: CameraPhotoErrorCode, readonly actualBytes?: number, readonly maxBytes?: number) { super(code); }
}
const check = (current: () => boolean) => { if (!current()) throw new Error('session_changed'); };
async function hasWebpSignature(body: Blob, current: () => boolean): Promise<boolean> {
  const reader = body.stream().getReader();
  const header = new Uint8Array(12); let offset = 0;
  try {
    while (offset < header.length) {
      check(current); const part = await reader.read(); check(current);
      if (part.done) return false;
      const length = Math.min(part.value.length, header.length - offset);
      header.set(part.value.subarray(0, length), offset); offset += length;
    }
    return String.fromCharCode(...header.subarray(0, 4)) === 'RIFF' && String.fromCharCode(...header.subarray(8, 12)) === 'WEBP';
  } finally { await reader.cancel().catch(() => {}); }
}
/** Only an ImageManipulator-created UUID WebP within this app's cache is removable. */
export function isCameraWebpCacheUri(cacheUri: string, uri: string): boolean {
  try {
    const root = new URL(cacheUri.endsWith('/') ? cacheUri : `${cacheUri}/`);
    const base = new URL('ImageManipulator/', root);
    const file = new URL(uri);
    return root.protocol === 'file:' && file.protocol === 'file:' && !file.host && !file.search && !file.hash && file.href.startsWith(base.href) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.webp$/i.test(file.href.slice(base.href.length));
  } catch { return false; }
}

/** Takes ownership of photo, but never of existing. Encoder results are also owned here. */
export async function prepareCameraPhotoCore(view: ChatView, existing: readonly AttachmentDraft[], photo: AttachmentDraft, current: () => boolean, encode: (photo: AttachmentDraft) => Promise<CameraEncodedPhoto>): Promise<AttachmentDraft> {
  let converted: CameraEncodedPhoto | undefined;
  let transferred = false;
  try {
    check(current);
    const limits = view.capabilities.images;
    if (!limits) throw new CameraPhotoError('images_unavailable');
    validateDrafts(view, existing);
    const images = existing.filter(item => item.kind === 'image');
    if (images.length >= limits.maxImagesPerMessage) throw new CameraPhotoError('camera_image_count_limit');
    if (photo.kind !== 'image' || !/^[A-Za-z0-9_-]{1,100}$/.test(photo.id) || existing.some(item => item.id === photo.id) || !photo.name || photo.name.length > 200 || !Number.isSafeInteger(photo.size) || photo.size < 0 || photo.size !== photo.body.size || photo.mediaType.length > 255) throw new Error('invalid_drafts');
    if (!photo.size || photo.mediaType === 'image/gif') throw new Error('invalid_images');
    const budget = Math.min(limits.maxImageBytes, limits.maxMessageImageBytes - images.reduce((sum, item) => sum + item.size, 0));
    if (budget <= 0) throw new CameraPhotoError('camera_image_budget_exhausted');
    if (photo.size <= budget) {
      validateDrafts(view, [...existing, photo]); check(current); transferred = true; return photo;
    }
    if (!limits.mediaTypes.includes('image/webp')) throw new CameraPhotoError('camera_webp_unsupported');
    try { converted = await encode(photo); } catch { check(current); throw new CameraPhotoError('camera_encoding_failed'); }
    check(current);
    if (!converted || converted.uri === photo.uri || !converted.uri || converted.body.type !== 'image/webp' || !Number.isSafeInteger(converted.body.size) || converted.body.size <= 0 || converted.width !== photo.width || converted.height !== photo.height) throw new CameraPhotoError('camera_encoding_failed');
    const actual = converted.body.size;
    let validSignature: boolean;
    try { validSignature = await hasWebpSignature(converted.body, current); } catch { check(current); throw new CameraPhotoError('camera_encoding_failed'); }
    check(current);
    if (!validSignature) throw new CameraPhotoError('camera_encoding_failed');
    if (actual > budget) throw new CameraPhotoError('camera_image_too_large', actual, budget);
    let bytes: Uint8Array;
    try { bytes = new Uint8Array(await converted.body.arrayBuffer()); } catch { check(current); throw new CameraPhotoError('camera_encoding_failed'); }
    check(current);
    if (bytes.length !== actual || bytes.length < 12 || String.fromCharCode(...bytes.subarray(0, 4)) !== 'RIFF' || String.fromCharCode(...bytes.subarray(8, 12)) !== 'WEBP') throw new CameraPhotoError('camera_encoding_failed');
    const name = `${photo.name.replace(/\.[^.]*$/, '').slice(0, 195) || 'photo'}.webp`;
    const owned = converted;
    let released = false;
    const result: AttachmentDraft = { ...photo, name, mediaType: 'image/webp', size: actual, uri: owned.uri, body: owned.body, width: owned.width, height: owned.height, release() { if (!released) { released = true; owned.release(); } } };
    validateDrafts(view, [...existing, result]); check(current);
    photo.release(); transferred = true; return result;
  } catch (error) {
    if (!current()) throw new Error('session_changed');
    throw error;
  } finally {
    if (!transferred) { try { converted?.release(); } finally { photo.release(); } }
  }
}
