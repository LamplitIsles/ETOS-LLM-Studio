import React, { useState } from 'react';
import { StyleSheet } from 'react-native';
import { Tabs } from 'react-native-screens';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import type { SettingsTabsProps } from './SettingsTabs';

export function SettingsTabs({ tabs, page }: SettingsTabsProps) {
  const [selection, setSelection] = useState({ selectedScreenKey: tabs[0].key, baseProvenance: 0 });
  return <Tabs.Host navStateRequest={selection} ios={{ tabBarTintColor: '#55739a', tabBarControllerMode: 'tabBar', tabBarMinimizeBehavior: 'never' }} onTabSelected={event => setSelection({ selectedScreenKey: event.nativeEvent.selectedScreenKey, baseProvenance: event.nativeEvent.provenance })}>
    {tabs.map(tab => <Tabs.Screen key={tab.key} screenKey={tab.key} title={tab.label} tabBarItemAccessibilityLabel={tab.label} ios={{ icon: { type: 'sfSymbol', name: typeof tab.symbol === 'string' ? tab.symbol : tab.symbol.ios! } }}>
      <SafeAreaProvider style={styles.screen}><SafeAreaView edges={['bottom']} style={[styles.screen, { backgroundColor: page }]}>{tab.content}</SafeAreaView></SafeAreaProvider>
    </Tabs.Screen>)}
  </Tabs.Host>;
}
const styles = StyleSheet.create({ screen: { flex: 1 } });
