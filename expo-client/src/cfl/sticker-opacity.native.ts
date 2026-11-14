import { requireOptionalNativeModule } from 'expo-modules-core';
import { classifyStickerOpacityWithNative } from './sticker-opacity-native-core';
import type { StickerOpacity } from './sticker-opacity-core';
import type { ImageData } from './transport';

/** Old development binaries without the native decoder conservatively return unknown. */
export function classifyStickerOpacity(image: ImageData, current: () => boolean, signal?: AbortSignal): Promise<StickerOpacity> {
  return classifyStickerOpacityWithNative(image, current, signal, () => requireOptionalNativeModule('ETOSInputArea'));
}
