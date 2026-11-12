import React from 'react';
import { Button as SwiftButton, Host, Image } from '@expo/ui/swift-ui';
import { View } from 'react-native';
import { isGlassEffectAPIAvailable, isLiquidGlassAvailable } from 'expo-glass-effect';
import { accessibilityLabel as a11yLabel, buttonBorderShape, buttonStyle, disabled as disabledModifier, font, foregroundColor, frame, labelStyle } from '@expo/ui/swift-ui/modifiers';
import type { ButtonProps } from './Button';
import { Surface } from './Surface';
import { useAppearance } from './appearance';

export function Button({ children, accessibilityLabel, onPress, disabled, variant, icon, size }: ButtonProps) {
  const label = accessibilityLabel ?? children ?? '';
  const { reduceTransparency } = useAppearance();
  const nativeGlass = !reduceTransparency && isLiquidGlassAvailable() && isGlassEffectAPIAvailable();
  if (size === 'overlay' && icon) return <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
    <View pointerEvents="none" style={{ position: 'absolute', width: 24, height: 24, borderRadius: 12, backgroundColor: 'rgba(0,0,0,0.65)' }} />
    <Host matchContents ignoreSafeArea="keyboard"><SwiftButton onPress={onPress} modifiers={[buttonStyle('plain'), a11yLabel(label), disabledModifier(!!disabled)]}>
      <Image systemName={icon.ios} modifiers={[font({ size: 10, weight: 'bold' }), foregroundColor('#ffffff'), frame({ width: 44, height: 44 })]} />
    </SwiftButton></Host>
  </View>;
  if ((size === 'attachment' || size === 'navigation') && icon && nativeGlass) {
    const dimension = size === 'attachment' ? 64 : 44;
    const labelDimension = size === 'attachment' ? 48 : 28;
    return <View style={{ width: dimension, height: dimension, alignItems: 'center', justifyContent: 'center' }}>
      <Host matchContents ignoreSafeArea="keyboard"><SwiftButton onPress={onPress}
        modifiers={[buttonStyle('glass'), buttonBorderShape('circle'), frame({ width: dimension, height: dimension }), a11yLabel(label), disabledModifier(!!disabled)]}>
        <Image systemName={icon.ios} modifiers={[font({ size: size === 'attachment' ? 26 : 17, weight: 'semibold' }), frame({ width: labelDimension, height: labelDimension })]} />
      </SwiftButton>
      </Host>
    </View>;
  }
  if (size === 'attachment' && icon) return <View style={{ width: 64, height: 64, alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.45 : 1 }}>
    <Surface style={{ width: 64, height: 64, borderRadius: 32, position: 'absolute' }}>{null}</Surface>
    <Host matchContents ignoreSafeArea="keyboard"><SwiftButton onPress={onPress} modifiers={[buttonStyle('plain'), a11yLabel(label), disabledModifier(!!disabled)]}>
      <Image systemName={icon.ios} modifiers={[font({ size: 26 }), frame({ width: 64, height: 64, alignment: 'center' })]} />
    </SwiftButton></Host>
  </View>;
  if (size === 'navigation' && icon) return <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
    <Surface style={{ width: 40, height: 40, borderRadius: 20, position: 'absolute' }}>{null}</Surface>
    <Host matchContents ignoreSafeArea="keyboard"><SwiftButton onPress={onPress} modifiers={[buttonStyle('plain'), a11yLabel(label), disabledModifier(!!disabled)]}>
      <Image systemName={icon.ios} modifiers={[font({ size: 17, weight: 'semibold' }), frame({ width: 44, height: 44 })]} />
    </SwiftButton></Host>
  </View>;
  return <View style={icon ? { alignSelf: 'flex-end' } : undefined}><Host matchContents ignoreSafeArea="keyboard">
    <SwiftButton label={icon ? label : children} systemImage={icon?.ios} onPress={onPress}
      modifiers={[buttonStyle(variant === 'prominent' ? 'glassProminent' : variant === 'ghost' ? 'plain' : 'glass'), buttonBorderShape(icon ? 'circle' : 'capsule'), ...(icon ? [labelStyle('iconOnly'), frame({ width: 44, height: 44 })] : []), a11yLabel(label), disabledModifier(!!disabled)]} />
  </Host></View>;
}
