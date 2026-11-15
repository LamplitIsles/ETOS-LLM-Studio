import React from 'react';
import { Pressable, View } from 'react-native';
import { Host, RNHostView } from '@expo/ui';
import { Button, ContextMenu } from '@expo/ui/swift-ui';
import { disabled } from '@expo/ui/swift-ui/modifiers';

export function ChatImageActions({ children, width, height, canFavorite, favoriteBusy, onOpen, onFavorite }: {
  children: React.ReactNode; width: number; height: number; canFavorite: boolean; favoriteBusy: boolean; onOpen: () => void; onFavorite: () => void;
}) {
  const trigger = <Pressable accessibilityRole="button" accessibilityLabel="查看图片" onPress={onOpen} style={{ width, height }}>{children}</Pressable>;
  if (!canFavorite) return trigger;
  return <View style={{ width, height }}><Host ignoreSafeArea="all" style={{ width, height }}>
    <ContextMenu>
      <ContextMenu.Trigger><RNHostView matchContents>{trigger}</RNHostView></ContextMenu.Trigger>
      <ContextMenu.Items><Button label="收藏表情" systemImage="heart" onPress={onFavorite} modifiers={[disabled(favoriteBusy)]} /></ContextMenu.Items>
    </ContextMenu>
  </Host></View>;
}
