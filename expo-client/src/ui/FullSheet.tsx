import React, { useEffect } from 'react';
import { BottomSheet } from '@expo/ui';

export function FullSheet({ open, color, onRequestClose, onDismiss, children, testID }: { open: boolean; color: string; nativeGlass?: boolean; onRequestClose: () => void; onDismiss: () => void; children: React.ReactNode; testID: string }) {
  useEffect(() => { if (!open) onDismiss(); }, [open, onDismiss]);
  return <BottomSheet isPresented={open} onDismiss={onRequestClose} snapPoints={['full']} containerColor={color} testID={testID}>{children}</BottomSheet>;
}
