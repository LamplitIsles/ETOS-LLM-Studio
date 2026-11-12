import React from 'react';
import { Text } from 'react-native';
import { Button, Host } from '@expo/ui';
import { SymbolView } from 'expo-symbols';

export function NavigationButton({ label, symbol, selected, dark, width, onPress }: {
  label: string; symbol: React.ComponentProps<typeof SymbolView>['name']; selected: boolean; dark: boolean; width: number; onPress: () => void;
}) {
  return <Host ignoreSafeArea="all" matchContents><Button onPress={onPress} variant="text"
    style={{ width, height: 48, paddingHorizontal: 0, borderRadius: 24, backgroundColor: selected ? (dark ? '#48515f' : '#dce5f1') : 'transparent' }}>
    <SymbolView name={symbol} size={23} tintColor={selected ? '#55739a' : dark ? '#aaaeb8' : '#747984'} />
    <Text style={{ position: 'absolute', width: 1, height: 1, opacity: 0 }}>{label}{selected ? '，当前' : ''}</Text>
  </Button></Host>;
}
