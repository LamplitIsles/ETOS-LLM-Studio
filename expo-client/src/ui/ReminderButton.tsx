import React, { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Host } from '@expo/ui';
import { useAppearance } from './appearance';

export function ReminderButton({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  const { dark } = useAppearance();
  const content = `⏰ ${expanded ? text : text.replace(/[\r\n]+/g, ' ')}`;
  return <View style={{ maxWidth: '90%', borderRadius: 14, backgroundColor: dark ? '#343941' : '#e3e6e9' }}>
    <Host matchContents ignoreSafeArea="all"><Button variant="text" onPress={() => setExpanded(!expanded)} style={{ paddingHorizontal: 12, paddingVertical: 8 }}>
      <Text numberOfLines={expanded ? undefined : 1} style={{ color: dark ? '#f5f6f7' : '#252832', fontSize: 15, lineHeight: 21 }}>{content}</Text>
    </Button></Host>
  </View>;
}
