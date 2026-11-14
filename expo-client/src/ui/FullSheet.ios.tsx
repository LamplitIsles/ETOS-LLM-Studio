import React from 'react';
import { BottomSheet, Group, Host } from '@expo/ui/swift-ui';
import { frame, padding, presentationBackground, presentationDetents, presentationDragIndicator } from '@expo/ui/swift-ui/modifiers';

export function FullSheet({ open, color, onRequestClose, onDismiss, children, testID }: { open: boolean; color: string; onRequestClose: () => void; onDismiss: () => void; children: React.ReactNode; testID: string }) {
  return <Host style={{ position: 'absolute' }} pointerEvents="none">
    <BottomSheet isPresented={open} onIsPresentedChange={value => { if (!value) onRequestClose(); }} onDismiss={onDismiss} testID={testID}>
      <Group modifiers={[frame({ maxWidth: Infinity, alignment: 'topLeading' }), padding({ top: 16, bottom: 0, leading: 16, trailing: 16 }), presentationDragIndicator('visible'), presentationDetents(['large']), presentationBackground(color)]}>{children}</Group>
    </BottomSheet>
  </Host>;
}
