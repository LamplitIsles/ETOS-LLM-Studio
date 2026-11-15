import React from 'react';
import { Text, View } from 'react-native';
import { useAppearance } from './appearance';

export function ReminderMessage({ text }: { text: string }) {
  const { dark } = useAppearance();
  return <View testID="reminder-message"
    style={{ width: '100%', paddingHorizontal: 12, paddingVertical: 8, borderRadius: 14, backgroundColor: dark ? '#343941' : '#e3e6e9' }}>
    <Text testID="reminder-text" numberOfLines={1} ellipsizeMode="tail" selectable
      style={{ color: dark ? '#f5f6f7' : '#252832', fontSize: 15, lineHeight: 21 }}>{`⏰ ${text.replace(/[\r\n]+/g, ' ')}`}</Text>
  </View>;
}
