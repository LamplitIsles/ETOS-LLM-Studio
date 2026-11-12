import React from 'react';
import { Pressable, Text, View } from 'react-native';
import { Surface } from './Surface';

export function ContextButton({ percentage, dark, onPress }: { percentage: number | null; dark: boolean; onPress: () => void }) {
  return <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
    <Surface style={{ position: 'absolute', width: 40, height: 40, borderRadius: 20 }}>{null}</Surface>
    <Pressable accessibilityRole="button" accessibilityLabel="上下文" accessibilityValue={{ text: percentage === null ? '用量未知' : `已使用 ${percentage}%` }} onPress={onPress} style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
      <View style={{ width: 29, height: 29, borderRadius: 15, borderWidth: 2, borderColor: dark ? '#cbd4df' : '#647b93', alignItems: 'center', justifyContent: 'center' }}><Text style={{ color: dark ? '#f0f2f6' : '#273647', fontSize: 9, fontWeight: '600' }}>{percentage === null ? '–' : `${percentage}%`}</Text></View>
    </Pressable>
  </View>;
}
