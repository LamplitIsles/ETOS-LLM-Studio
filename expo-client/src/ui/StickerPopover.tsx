import React from 'react';

// The native popover is used only on iOS; other platforms keep the panel preview.
export function StickerPopover({ children }: { shown: boolean; onDismiss: () => void; size: number; children: React.ReactElement; preview: React.ReactElement }) {
  return children;
}
