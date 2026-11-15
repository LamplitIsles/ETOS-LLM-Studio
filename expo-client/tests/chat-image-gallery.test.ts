import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imageGallery } from '../src/ui/chatImageGallery';
import type { TimelineRow } from '../src/ui/timelineRows';
import type { ImageRef } from '../vendor/contracts/src/index';

const image = (id: string, sticker = false): ImageRef => ({ attachmentId: id, name: id, mediaType: 'image/png', availability: 'available', ...(sticker ? { sticker: { id: 'sticker', version: 'v1' } } : {}) });
const row = (id: string, images: ImageRef[]): TimelineRow => ({ _id: id, user: { _id: 'me' }, text: '', createdAt: 0, pendingImages: images });

test('loaded photos keep row identity and stop at an unproven gap', () => {
  const gap: TimelineRow = { ...row('gap', []), kind: 'gap' };
  const groups = imageGallery([row('a', [image('same'), image('sticker', true)]), row('b', [image('same')]), gap, row('c', [image('last')])], {});
  assert.deepEqual(groups.map(group => group.map(item => item.id)), [['same', 'same'], ['last']]);
  assert.notEqual(groups[0][0].key, groups[0][1].key);
});

test('pending local photos retain their order and operation identity', () => {
  const pending: TimelineRow = { ...row('pending', [image('one'), image('two')]), operationId: 'op' };
  const groups = imageGallery([pending], { op: [{ attachmentId: 'two' }, { attachmentId: 'one' }] });
  assert.deepEqual(groups[0].map(item => [item.id, item.operationId]), [['two', 'op'], ['one', 'op']]);
});
