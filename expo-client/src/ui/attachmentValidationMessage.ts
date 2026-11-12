import type { ChatView } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from '../cfl/drafts';
import { CameraPhotoError } from '../cfl/camera-photo-core';

function size(bytes: number): string {
  if (bytes < 1000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${(bytes / 1000).toFixed(1)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

export function cameraPhotoMessage(error: CameraPhotoError): string {
  switch (error.code) {
    case 'images_unavailable': return '当前服务暂不支持发送图片。';
    case 'camera_image_count_limit': return '已达到当前服务的图片数量上限。';
    case 'camera_image_budget_exhausted': return '已有图片已达到当前服务的总大小上限。';
    case 'camera_webp_unsupported': return '当前服务不支持 WebP，无法压缩这张照片。';
    case 'camera_image_too_large': return error.actualBytes !== undefined && error.maxBytes !== undefined
      ? `照片压缩后约为 ${size(error.actualBytes)}，仍超过可用上限（约 ${size(error.maxBytes)}）。`
      : '照片压缩后仍超过当前服务的大小上限。';
    case 'camera_encoding_failed': return '照片压缩失败，请重新拍照后重试。';
  }
}

/** Explain the existing validation without changing the service's limits. */
export function attachmentValidationMessage(view: ChatView, drafts: readonly AttachmentDraft[], error: unknown): string {
  const code = error instanceof Error ? error.message : '';
  if (code === 'images_unavailable') return '当前服务暂不支持发送图片。';
  if (code === 'files_unavailable') return '当前服务暂不支持发送文件。';
  if (code === 'invalid_images' && view.capabilities.images) {
    const limits = view.capabilities.images;
    const images = drafts.filter(d => d.kind === 'image');
    if (images.length > limits.maxImagesPerMessage) return `最多可选择 ${limits.maxImagesPerMessage} 张图片。`;
    const empty = images.find(d => !d.size);
    if (empty) return '图片为空或无法读取，请重新拍照或选择。';
    const oversized = images.find(d => d.size > limits.maxImageBytes);
    if (oversized) return `图片大小约为 ${size(oversized.size)}，超过当前服务单张上限（约 ${size(limits.maxImageBytes)}）。`;
    const unsupported = images.find(d => !limits.mediaTypes.includes(d.mediaType as typeof limits.mediaTypes[number]));
    if (unsupported) return `当前服务不支持此图片格式（${unsupported.mediaType || '未知'}）；支持 ${limits.mediaTypes.join('、')}。`;
    const total = images.reduce((sum, item) => sum + item.size, 0);
    if (total > limits.maxMessageImageBytes) return `图片总大小约为 ${size(total)}，超过当前服务总上限（约 ${size(limits.maxMessageImageBytes)}）。`;
  }
  if (code === 'invalid_files' && view.capabilities.files) {
    const limits = view.capabilities.files;
    const files = drafts.filter(d => d.kind === 'file');
    if (files.length > limits.maxFilesPerMessage) return `最多可选择 ${limits.maxFilesPerMessage} 个文件。`;
    const oversized = files.find(d => d.size > limits.maxFileBytes);
    if (oversized) return `文件大小约为 ${size(oversized.size)}，超过当前服务单个上限（约 ${size(limits.maxFileBytes)}）。`;
    const total = files.reduce((sum, item) => sum + item.size, 0);
    if (total > limits.maxMessageFileBytes) return `文件总大小约为 ${size(total)}，超过当前服务总上限（约 ${size(limits.maxMessageFileBytes)}）。`;
  }
  return '所选附件超出数量、格式或大小限制。';
}
