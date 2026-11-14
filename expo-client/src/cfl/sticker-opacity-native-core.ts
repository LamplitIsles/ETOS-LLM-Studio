import { classifyStickerOpacityCore, type StickerOpacity } from './sticker-opacity-core';
import type { ImageData } from './transport';

type NativeOpacity = { classifyStaticImageOpacity?: (bytes: Uint8Array, contentType: string, width: number, height: number) => Promise<string> };

/** Injected lookup lets old binaries safely omit this method. */
export function classifyStickerOpacityWithNative(image: ImageData, current: () => boolean, signal: AbortSignal | undefined, lookup: () => NativeOpacity | null): Promise<StickerOpacity> {
  return classifyStickerOpacityCore(image, current, signal, async (value, info) => {
    const native = lookup();
    if (typeof native?.classifyStaticImageOpacity !== 'function') return 'unknown';
    const result = await native.classifyStaticImageOpacity(value.bytes, info.contentType, info.width, info.height);
    return result === 'opaque' || result === 'transparent' ? result : 'unknown';
  });
}
