import React from 'react';
import { BottomSheet, Group, Host } from '@expo/ui/swift-ui';
import { frame, padding, presentationBackground, presentationDetents, presentationDragIndicator } from '@expo/ui/swift-ui/modifiers';

// The universal sheet does not forward SwiftUI's onDismiss. Wait for that
// event before returning focus to the chat input.
export function StickerSearchSheet({ open, color, onRequestClose, onDismiss, children }: {
  open: boolean; color: string; onRequestClose: () => void; onDismiss: () => void; children: React.ReactNode;
}) {
  return <Host style={{ position: 'absolute' }} pointerEvents="none">
    <BottomSheet isPresented={open} onIsPresentedChange={value => { if (!value) onRequestClose(); }} onDismiss={onDismiss} testID="sticker-search-sheet">
      <Group modifiers={[frame({ maxWidth: Infinity, alignment: 'topLeading' }), padding({ top: 16, bottom: 0, leading: 16, trailing: 16 }), presentationDragIndicator('visible'), presentationDetents(['medium']), presentationBackground(color)]}>{children}</Group>
    </BottomSheet>
  </Host>;
}
