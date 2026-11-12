import React from 'react';
import { View } from 'react-native';
import { Button, Host, RNHostView } from '@expo/ui/swift-ui';
import { accessibilityLabel, buttonStyle, disabled as disabledModifier, frame } from '@expo/ui/swift-ui/modifiers';

export function ImageButton({ label, onPress, disabled, children, size = 68 }: { label: string; onPress: () => void; disabled?: boolean; children: React.ReactNode; size?: number }) {
  return <Host matchContents ignoreSafeArea="keyboard"><Button onPress={onPress}
    modifiers={[buttonStyle('plain'), frame({ width: size, height: size }), accessibilityLabel(label), disabledModifier(!!disabled)]}>
    <RNHostView matchContents><View pointerEvents="none" style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>{children}</View></RNHostView>
  </Button></Host>;
}
