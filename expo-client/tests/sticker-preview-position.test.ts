import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stickerPreviewPosition, STICKER_PREVIEW_HEIGHT } from '../src/ui/stickerPreviewPosition';

test('preview follows the pressed sticker and keeps its tail inside the bubble', () => {
  const host = { x: 0, y: 500, width: 390 };
  const center = stickerPreviewPosition(host, { x: 195, top: 550 });
  assert.equal(center.left + center.tailX, 195);
  assert.equal(host.y + center.top + STICKER_PREVIEW_HEIGHT + 8, 550);
  const left = stickerPreviewPosition(host, { x: 10, top: 550 });
  assert.equal(left.left, 8);
  assert.equal(left.tailX, 18);
  const right = stickerPreviewPosition(host, { x: 380, top: 550 });
  assert.equal(right.left + right.width, 382);
  assert.equal(right.tailX, right.width - 18);
});

test('preview does not extend past the top or sides of a narrow window', () => {
  const result = stickerPreviewPosition({ x: 20, y: 40, width: 180 }, { x: 22, top: 80 });
  assert.equal(result.width, 164);
  assert.equal(result.left, 8);
  assert.equal(result.top + 40, 8);
});
