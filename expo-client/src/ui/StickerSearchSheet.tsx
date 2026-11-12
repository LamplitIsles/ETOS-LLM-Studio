import React from 'react';
import { BottomSheet } from '@expo/ui';

export function StickerSearchSheet({ open, color, onRequestClose, onDismiss: _onDismiss, children }: {
  open: boolean; color: string; onRequestClose: () => void; onDismiss: () => void; children: React.ReactNode;
}) {
  return <BottomSheet isPresented={open} onDismiss={onRequestClose} snapPoints={['half']} testID="sticker-search-sheet" containerColor={color}>{children}</BottomSheet>;
}
