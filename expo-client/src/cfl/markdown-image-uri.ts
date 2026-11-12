import { scopedImageUri } from './markdown-image-uri-core';
import type { ImageData } from './transport';

/** Release on unmount/session change; browsers manage the Blob's storage. */
export function createMarkdownImageUri(image: ImageData, isCurrent: () => boolean, signal?: AbortSignal) {
  return scopedImageUri(image, isCurrent, signal, { async create(value) {
    const uri = URL.createObjectURL(new Blob([new Uint8Array(value.bytes)], { type: value.contentType }));
    return { uri, release: () => URL.revokeObjectURL(uri) };
  } });
}
