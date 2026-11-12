import React from 'react';
import { StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { Surface } from './Surface';

/** The same message material and shape in the timeline and search context. */
export function MessageSurface({ mine, children, style }: { mine: boolean; children: React.ReactNode; style?: StyleProp<ViewStyle> }) {
  return <Surface tint={mine ? '#536d94' : undefined} style={[styles.bubble, mine && styles.mine, style]}>{children}</Surface>;
}

const styles = StyleSheet.create({
  bubble: { borderRadius: 22, paddingHorizontal: 15, paddingVertical: 11 },
  mine: { borderBottomRightRadius: 7 },
});
