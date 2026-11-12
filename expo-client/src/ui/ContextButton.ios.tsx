import React from 'react';
import { View } from 'react-native';
import { Button, Host, Text } from '@expo/ui/swift-ui';
import { accessibilityLabel, buttonStyle, font, foregroundColor, frame } from '@expo/ui/swift-ui/modifiers';
import { Surface } from './Surface';

export function ContextButton({ percentage, dark, onPress }: { percentage: number | null; dark: boolean; onPress: () => void }) {
  return <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
    <Surface style={{ position: 'absolute', width: 40, height: 40, borderRadius: 20 }}>{null}</Surface>
    <View pointerEvents="none" style={{ position: 'absolute', width: 29, height: 29, borderRadius: 15, borderWidth: 2, borderColor: dark ? '#cbd4df' : '#647b93' }} />
    <Host matchContents ignoreSafeArea="keyboard"><Button onPress={onPress} modifiers={[buttonStyle('plain'), accessibilityLabel(percentage === null ? '上下文，用量未知' : `上下文，已使用 ${percentage}%`)]}>
      <Text modifiers={[font({ size: 9, weight: 'semibold' }), foregroundColor(dark ? '#f0f2f6' : '#273647'), frame({ width: 44, height: 44 })]}>{percentage === null ? '–' : `${percentage}%`}</Text>
    </Button></Host>
  </View>;
}
