import type { StickerCache } from './sticker-cache-store';

/** Web has no expo-file-system implementation. */
export function createStickerCache(): StickerCache | undefined { return undefined; }
