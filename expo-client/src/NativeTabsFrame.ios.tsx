import React, { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Tabs } from 'react-native-screens';
import type { NativeTabsFrameProps } from './NativeTabsFrame';

const items = [
  { key: 'memories', label: '纪念', symbol: 'heart' },
  { key: 'diary', label: '日记', symbol: 'book' },
  { key: 'album', label: '相册', symbol: 'photo.on.rectangle' },
  { key: 'wake', label: '唤醒', symbol: 'alarm' },
];

export function NativeTabsFrame({ header, ink, page }: NativeTabsFrameProps) {
  const [selection, setSelection] = useState({ selectedScreenKey: 'memories', baseProvenance: 0 });
  return <Tabs.Host navStateRequest={selection} ios={{ tabBarTintColor: '#55739a', tabBarControllerMode: 'tabBar', tabBarMinimizeBehavior: 'never' }} onTabSelected={event => setSelection({ selectedScreenKey: event.nativeEvent.selectedScreenKey, baseProvenance: event.nativeEvent.provenance })}>
    {items.map(item => <Tabs.Screen key={item.key} screenKey={item.key} title="" tabBarItemAccessibilityLabel={item.label} ios={{ icon: { type: 'sfSymbol', name: item.symbol } }}>
      <View style={[styles.screen, { backgroundColor: page }]}>{header}<View style={styles.page}><Text style={[styles.title, { color: ink }]}>{item.label}</Text><Text style={{ color: ink, opacity: 0.6 }}>这个页面正在准备中</Text></View></View>
    </Tabs.Screen>)}
  </Tabs.Host>;
}
const styles = StyleSheet.create({ screen: { flex: 1 }, page: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10 }, title: { fontSize: 26, fontWeight: '700' } });
