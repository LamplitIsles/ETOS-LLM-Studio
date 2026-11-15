import type { ImageRef } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from '../cfl/drafts';
import type { TimelineRow } from './timelineRows';

export type LocalImagePreview = { attachmentId: string; draft?: AttachmentDraft };
export type ImageViewerTarget = { id: string; key: string; operationId?: string; localUri?: string };
type ImageItem = { image?: ImageRef; local?: LocalImagePreview };

export function imageItemsFor(row: TimelineRow, localImages?: readonly LocalImagePreview[]): ImageItem[] {
  const images = (row.original?.images ?? row.pendingImages ?? []).filter(image => !image.sticker);
  const localIds = new Set(localImages?.map(image => image.attachmentId));
  return [...(localImages ?? []).map(local => ({ local, image: images.find(value => value.attachmentId === local.attachmentId) })),
    ...images.filter(image => !localIds.has(image.attachmentId)).map(image => ({ image, local: undefined }))]
    .filter(value => value.image || value.local?.draft);
}

export function imageTarget(row: TimelineRow, item: ImageItem): ImageViewerTarget {
  const id = item.image?.attachmentId ?? item.local!.attachmentId;
  return { id, key: JSON.stringify([row._id, id]), operationId: row.operationId, localUri: item.local?.draft?.uri };
}

/** A gap separates ranges whose relative order has not been established. */
export function imageGallery(rows: readonly TimelineRow[], localImages: Record<string, LocalImagePreview[]>): ImageViewerTarget[][] {
  const groups: ImageViewerTarget[][] = [[]];
  for (const row of rows) {
    if (row.kind === 'gap') { groups.push([]); continue; }
    const local = row.operationId ? localImages[row.operationId] : undefined;
    groups[groups.length - 1].push(...imageItemsFor(row, local).map(item => imageTarget(row, item)));
  }
  return groups;
}
