import React, { useState, type ReactNode } from 'react';
import { StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { NavigationButton } from './ui/NavigationButton';

export type NativeTabsFrameProps = { header: ReactNode; ink: string; page: string; dark: boolean; bottomInset: number };
const items: { label: string; symbol: React.ComponentProps<typeof SymbolView>['name'] }[] = [
  { label: '纪念', symbol: { ios: 'heart', web: 'favorite', android: 'favorite' } },
  { label: '日记', symbol: { ios: 'book', web: 'menu_book', android: 'menu_book' } },
  { label: '相册', symbol: { ios: 'photo.on.rectangle', web: 'photo_library', android: 'photo_library' } },
  { label: '唤醒', symbol: { ios: 'alarm', web: 'alarm', android: 'alarm' } },
];
export function NativeTabsFrame({ header, ink, page, dark, bottomInset }: NativeTabsFrameProps) {
  const [selected, setSelected] = useState('纪念');
  const { width } = useWindowDimensions();
  return <View style={[styles.screen, { backgroundColor: page }]}>{header}<View style={styles.content}><Text style={[styles.title, { color: ink }]}>{selected}</Text><Text style={{ color: ink, opacity: 0.6 }}>这个页面正在准备中</Text></View>
    <View testID="bottom-navigation" accessibilityRole="navigation" accessibilityLabel="伴侣空间导航" style={[styles.dock, { paddingBottom: Math.max(bottomInset, 12) }]}>
      {items.map(item => <NavigationButton key={item.label} label={item.label} symbol={item.symbol} selected={selected === item.label} dark={dark} width={Math.min(70, Math.max(44, (width - 40) / 4))} onPress={() => setSelected(item.label)} />)}
    </View>
  </View>;
}
const styles = StyleSheet.create({ screen: { flex: 1 }, content: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10 }, title: { fontSize: 26, fontWeight: '700' }, dock: { flexDirection: 'row', alignSelf: 'center', gap: 4, paddingTop: 8 } });
