import React, { useState } from 'react';
import { View } from 'react-native';
import { Button, ContextMenu, Host, Text } from '@expo/ui/swift-ui';
import { accessibilityHint, buttonStyle, font, lineLimit } from '@expo/ui/swift-ui/modifiers';
import * as Clipboard from 'expo-clipboard';
import { useAppearance } from './appearance';

export function ReminderButton({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  const { dark } = useAppearance();
  const content = `⏰ ${expanded ? text : text.replace(/[\r\n]+/g, ' ')}`;
  return <View style={{ maxWidth: '90%', paddingHorizontal: 12, paddingVertical: 8, borderRadius: 14, backgroundColor: dark ? '#343941' : '#e3e6e9' }}>
    <Host matchContents ignoreSafeArea="keyboard"><ContextMenu>
      <ContextMenu.Trigger><Button onPress={() => setExpanded(!expanded)} modifiers={[buttonStyle('plain'), accessibilityHint(expanded ? '收起提醒' : '展开提醒')]}>
        <Text modifiers={[font({ size: 15 }), expanded ? lineLimit() : lineLimit(1)]}>{content}</Text>
      </Button></ContextMenu.Trigger>
      <ContextMenu.Items><Button label="复制提醒" onPress={() => void Clipboard.setStringAsync(text)} /></ContextMenu.Items>
    </ContextMenu></Host>
  </View>;
}
