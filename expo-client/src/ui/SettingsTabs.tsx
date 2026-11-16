import React, { useState, type ReactNode } from 'react';
import { StyleSheet, View, useWindowDimensions } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { NavigationButton } from './NavigationButton';

export type SettingsTab = {
  key: string;
  label: string;
  symbol: React.ComponentProps<typeof SymbolView>['name'];
  content: ReactNode;
};
export type SettingsTabsProps = { tabs: SettingsTab[]; dark: boolean; page: string };

export function SettingsTabs({ tabs, dark, page }: SettingsTabsProps) {
  const [selected, setSelected] = useState(tabs[0].key);
  const { width } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  return <View style={[styles.screen, { backgroundColor: page }]}>
    {tabs.map(tab => <View key={tab.key} style={[styles.screen, { display: tab.key === selected ? 'flex' : 'none' }]}>{tab.content}</View>)}
    <View accessibilityRole="navigation" accessibilityLabel="设置导航" style={[styles.dock, { paddingBottom: Math.max(insets.bottom, 12) }]}>
      {tabs.map(tab => <NavigationButton key={tab.key} label={tab.label} symbol={tab.symbol} selected={selected === tab.key} dark={dark} width={Math.min(70, Math.max(44, (width - 40) / tabs.length))} onPress={() => setSelected(tab.key)} />)}
    </View>
  </View>;
}
const styles = StyleSheet.create({ screen: { flex: 1 }, dock: { flexDirection: 'row', alignSelf: 'center', gap: 4, paddingTop: 8 } });
