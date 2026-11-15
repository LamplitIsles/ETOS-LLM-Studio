import React from 'react';
import { View } from 'react-native';
import { Host, Text } from '@expo/ui';
import { Button, ContextMenu } from '@expo/ui/swift-ui';
import { frame } from '@expo/ui/swift-ui/modifiers';
import * as Clipboard from 'expo-clipboard';
import { useAppearance } from './appearance';

export function ReminderMessage({ text }: { text: string }) {
  const { dark } = useAppearance();
  const content = `⏰ ${text.replace(/[\r\n]+/g, ' ')}`;
  return <View testID="reminder-message" style={{ width: '100%', paddingHorizontal: 12, paddingVertical: 8, borderRadius: 14, backgroundColor: dark ? '#343941' : '#e3e6e9' }}>
    <Host ignoreSafeArea="all" style={{ width: '100%', height: 18 }}>
      <ContextMenu>
        <ContextMenu.Trigger><Text numberOfLines={1} textStyle={{ fontSize: 15, color: dark ? '#f5f6f7' : '#252832' }} modifiers={[frame({ maxWidth: Infinity, alignment: 'leading' })]}>{content}</Text></ContextMenu.Trigger>
        <ContextMenu.Items><Button label="复制提醒" onPress={() => void Clipboard.setStringAsync(text)} /></ContextMenu.Items>
      </ContextMenu>
    </Host>
  </View>;
}
