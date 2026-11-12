import React from 'react';
import { Button } from './Button';

export type AttachmentKind = 'image' | 'camera' | 'file';
export type AttachmentMenuProps = { onSelect: (kind: AttachmentKind) => void; onOpen: () => void; disabled: boolean };
/** Web opens the shared sheet; iOS uses its native Menu implementation. */
export function AttachmentMenu({ onOpen, disabled }: AttachmentMenuProps) {
  return <Button accessibilityLabel="附件" variant="ghost" icon={{ ios: 'paperclip', web: 'attach_file', android: 'attach_file' }} disabled={disabled} onPress={onOpen} />;
}
