import * as Crypto from 'expo-crypto';
import { File, Paths } from 'expo-file-system';
import { scopedImageUri } from './markdown-image-uri-core';
import type { ImageData } from './transport';

/** Only this unique temporary file is removed on release or failed creation. */
export function createMarkdownImageUri(image: ImageData, isCurrent: () => boolean, signal?: AbortSignal) {
  return scopedImageUri(image, isCurrent, signal, { async create(value) {
    const extension = ({ 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif' } as Record<string, string>)[value.contentType];
    const file = new File(Paths.cache, `etos-markdown-${Crypto.randomUUID()}.${extension}`);
    let created = false;
    try {
      file.create(); created = true; file.write(value.bytes);
      return { uri: file.uri, release: () => { try { file.delete(); } catch {} } };
    } catch (error) { if (created) { try { file.delete(); } catch {} } throw error; }
  } });
}
