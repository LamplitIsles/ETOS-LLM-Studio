import type { ImageData } from './transport';

export type MarkdownImageUri = { uri: string; release(): void };
export type ImageUriStore = { create(image: ImageData): Promise<MarkdownImageUri> };

/** Own exactly one generated resource; late creations are released, never published. */
export async function scopedImageUri(image: ImageData, isCurrent: () => boolean, signal: AbortSignal | undefined, store: ImageUriStore): Promise<MarkdownImageUri> {
  const check = () => {
    if (!isCurrent()) throw new Error('session_changed');
    if (signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
  };
  check();
  if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(image.contentType) || !image.bytes.length || image.bytes.length > 20 * 1024 * 1024) throw new Error('invalid_media');
  const handle = await store.create(image);
  let released = false;
  const release = () => { if (!released) { released = true; handle.release(); } };
  try { check(); } catch (error) { release(); throw error; }
  return { uri: handle.uri, release };
}
