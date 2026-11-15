export const STICKER_PREVIEW_WIDTH = 192;
export const STICKER_PREVIEW_HEIGHT = 216;

/** Place the bubble above its target while keeping its pointer and body on screen. */
export function stickerPreviewPosition(host: { x: number; y: number; width: number }, anchor: { x: number; top: number }) {
  const margin = 8;
  const width = Math.min(STICKER_PREVIEW_WIDTH, Math.max(0, host.width - 2 * margin));
  const anchorX = anchor.x - host.x;
  const left = Math.max(margin, Math.min(anchorX - width / 2, host.width - width - margin));
  const top = Math.max(margin - host.y, anchor.top - host.y - STICKER_PREVIEW_HEIGHT - margin);
  const tailX = Math.max(18, Math.min(anchorX - left, width - 18));
  return { left, top, width, tailX };
}
