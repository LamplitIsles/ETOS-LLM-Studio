import { classifyStickerOpacityCore, type StickerOpacity } from './sticker-opacity-core';
import type { ImageData } from './transport';

/** Web: inspect the original decoded pixels; no external URL or new request. */
export function classifyStickerOpacity(image: ImageData, current: () => boolean, signal?: AbortSignal): Promise<StickerOpacity> {
  return classifyStickerOpacityCore(image, current, signal, async (value, info) => {
    if (typeof createImageBitmap !== 'function' || typeof document === 'undefined') return 'unknown';
    const bitmap = await createImageBitmap(new Blob([new Uint8Array(value.bytes).buffer], { type: info.contentType }));
    try {
      if (bitmap.width !== info.width || bitmap.height !== info.height) return 'unknown';
      const canvas = document.createElement('canvas'); canvas.width = info.width; canvas.height = info.height;
      try {
        const context = canvas.getContext('2d', { willReadFrequently: true });
        if (!context) return 'unknown';
        context.clearRect(0, 0, info.width, info.height); context.drawImage(bitmap, 0, 0);
        const pixels = context.getImageData(0, 0, info.width, info.height).data;
        for (let i = 3; i < pixels.length; i += 4) if (pixels[i] !== 255) return 'transparent';
        return 'opaque';
      } finally { canvas.width = 0; canvas.height = 0; }
    } finally { bitmap.close(); }
  });
}
