import React from 'react';
import { BottomSheet, Group, Host, Rectangle } from '@expo/ui/swift-ui';
import { foregroundStyle, frame, glassEffect, padding, presentationBackground, presentationDetents, presentationDragIndicator } from '@expo/ui/swift-ui/modifiers';
import { isGlassEffectAPIAvailable, isLiquidGlassAvailable } from 'expo-glass-effect';
import { useAppearance } from './appearance';

export function FullSheet({ open, color, nativeGlass = false, horizontalPadding = 16, onRequestClose, onDismiss, children, testID }: { open: boolean; color: string; nativeGlass?: boolean; horizontalPadding?: number; onRequestClose: () => void; onDismiss: () => void; children: React.ReactNode; testID: string }) {
  const { reduceTransparency } = useAppearance();
  const glass = nativeGlass && !reduceTransparency && isLiquidGlassAvailable() && isGlassEffectAPIAvailable();
  return <Host style={{ position: 'absolute' }} pointerEvents="none">
    <BottomSheet isPresented={open} onIsPresentedChange={value => { if (!value) onRequestClose(); }} onDismiss={onDismiss} testID={testID} presentationBackground={glass ? <Rectangle modifiers={[foregroundStyle('#00000000'), glassEffect({ shape: 'rectangle' })]} /> : undefined}>
      <Group modifiers={[frame({ maxWidth: Infinity, alignment: 'topLeading' }), padding({ top: 16, bottom: 0, leading: horizontalPadding, trailing: horizontalPadding }), presentationDragIndicator('visible'), presentationDetents(['large']), ...(!glass ? [presentationBackground(color)] : [])]}>{children}</Group>
    </BottomSheet>
  </Host>;
}
