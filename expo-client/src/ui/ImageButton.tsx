import React from 'react';
import { Text, View } from 'react-native';
import { Button, Host } from '@expo/ui';

type Props = { label: string; onPress: () => void; disabled?: boolean; children: React.ReactNode; size?: number };

export function ImageButton({ label, onPress, disabled, children, size = 68 }: Props) {
  return <Host ignoreSafeArea="all" matchContents><Button onPress={onPress} disabled={disabled} variant="text"
    style={{ width: size, height: size, paddingHorizontal: 0, borderRadius: 12 }}>
    <View pointerEvents="none" style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>{children}</View>
    <Text style={{ position: 'absolute', width: 1, height: 1, opacity: 0 }}>{label}</Text>
  </Button></Host>;
}
