import React, { useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import { Button } from './Button';

export function ChatImageActions({ children, width, height, canFavorite, favoriteBusy, onOpen, onFavorite }: {
  children: React.ReactNode; width: number; height: number; canFavorite: boolean; favoriteBusy: boolean; onOpen: () => void; onFavorite: () => void;
}) {
  const [menu, setMenu] = useState(false);
  return <View style={{ width, height }}>
    <Pressable accessibilityRole="button" accessibilityLabel="查看图片" onPress={() => { setMenu(false); onOpen(); }} onLongPress={canFavorite ? () => setMenu(true) : undefined} style={{ width, height }}>{children}</Pressable>
    {canFavorite && <View style={{ position: 'absolute', top: 0, right: 0 }}><Button size="overlay" disabled={favoriteBusy} accessibilityLabel="图片操作" icon={{ ios: 'ellipsis', web: 'more_horiz', android: 'more_horiz' }} onPress={() => setMenu(!menu)} /></View>}
    {menu && canFavorite && <View style={{ position: 'absolute', top: 38, right: 4, zIndex: 2, backgroundColor: '#30343a', borderRadius: 10 }}>
      <Pressable accessibilityRole="button" disabled={favoriteBusy} onPress={() => { setMenu(false); onFavorite(); }} style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 14 }}><Text style={{ color: '#fff' }}>收藏表情</Text></Pressable>
    </View>}
  </View>;
}
