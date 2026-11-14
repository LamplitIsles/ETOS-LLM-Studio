import React from 'react';
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import { GlassView, isGlassEffectAPIAvailable, isLiquidGlassAvailable } from 'expo-glass-effect';
import { useAppearance } from './appearance';

export function Surface({ children, style, tint, interactive = false }: { children: React.ReactNode; style?: StyleProp<ViewStyle>; tint?: string; interactive?: boolean }) {
  const { dark, reduceTransparency } = useAppearance();
  const glass = !reduceTransparency && isLiquidGlassAvailable() && isGlassEffectAPIAvailable();
  const fallback = tint ?? (dark ? '#30343a' : '#f4f5f7');
  if (glass && interactive) return <GlassView isInteractive glassEffectStyle="regular" tintColor={tint} style={style}>{children}</GlassView>;
  return <View style={[{ overflow: 'hidden', backgroundColor: glass ? 'transparent' : fallback }, style]}>
    {glass && <GlassView pointerEvents="none" glassEffectStyle="regular" tintColor={tint} style={StyleSheet.absoluteFill} />}
    {children}
  </View>;
}
