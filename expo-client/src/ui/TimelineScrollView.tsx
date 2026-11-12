import React from 'react';
import { StyleSheet, View } from 'react-native';
import { MaskedView } from '@expo/ui/community/masked-view';

export function TimelineViewport({ children }: { children: React.ReactNode }) {
  return <MaskedView style={styles.fill} maskElement={<View style={styles.fill}>
    <View style={styles.top} />
    <View style={styles.middle} />
    <View style={styles.bottom} />
  </View>}>{children}</MaskedView>;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  top: { height: 20, backgroundImage: 'linear-gradient(180deg, transparent, black)' },
  middle: { flex: 1, backgroundColor: 'black' },
  bottom: { height: 20, backgroundImage: 'linear-gradient(0deg, transparent, black)' },
});
