import React from 'react';
import { Text, View } from 'react-native';
import { Button as ExpoButton, Host } from '@expo/ui';
import { SymbolView } from 'expo-symbols';
import { useAppearance } from './appearance';

export type ButtonProps = {
  children?: string; accessibilityLabel?: string; onPress: () => void; disabled?: boolean;
  variant?: 'prominent' | 'ghost' | 'soft'; size?: 'sm' | 'navigation' | 'overlay' | 'circle' | 'attachment';
  icon?: { ios: 'arrow.up' | 'arrow.down' | 'face.smiling' | 'keyboard' | 'plus' | 'paperclip' | 'xmark' | 'heart' | 'heart.fill' | 'ellipsis' | 'chevron.left' | 'magnifyingglass' | 'chart.bar' | 'gearshape' | 'photo.on.rectangle' | 'camera' | 'doc'; web: 'arrow_upward' | 'arrow_downward' | 'sentiment_satisfied' | 'keyboard' | 'add' | 'attach_file' | 'close' | 'favorite' | 'favorite_border' | 'more_horiz' | 'arrow_back' | 'search' | 'monitoring' | 'settings' | 'photo_library' | 'photo_camera' | 'description'; android: 'arrow_upward' | 'arrow_downward' | 'sentiment_satisfied' | 'keyboard' | 'add' | 'attach_file' | 'close' | 'favorite' | 'favorite_border' | 'more_horiz' | 'arrow_back' | 'search' | 'monitoring' | 'settings' | 'photo_library' | 'photo_camera' | 'description' };
};

export function Button({ children, accessibilityLabel, onPress, disabled, variant, icon, size }: ButtonProps) {
  const label = accessibilityLabel ?? children ?? '';
  const { dark } = useAppearance();
  const navigation = size === 'navigation' && !!icon;
  const attachment = size === 'attachment' && !!icon;
  const circle = !!icon && (navigation || size === 'circle');
  if (size === 'overlay' && icon) return <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
    <View pointerEvents="none" style={{ position: 'absolute', width: 24, height: 24, borderRadius: 12, backgroundColor: 'rgba(0,0,0,0.65)' }} />
    <Host ignoreSafeArea="all" matchContents><ExpoButton onPress={onPress} disabled={disabled} variant="text" style={{ width: 44, height: 44, paddingHorizontal: 0 }}>
      <SymbolView name={icon} size={12} tintColor="#fff" /><Text style={{ position: 'absolute', width: 1, height: 1, opacity: 0 }}>{label}</Text>
    </ExpoButton></Host>
  </View>;
  if (attachment && icon) return <View style={{ width: 64, height: 64, alignItems: 'center', justifyContent: 'center' }}><Host ignoreSafeArea="all" matchContents><ExpoButton onPress={onPress} disabled={disabled} variant="text" style={{ width: 64, height: 64, borderRadius: 32, paddingHorizontal: 0, backgroundColor: dark ? 'rgba(255,255,255,0.12)' : 'rgba(28,38,50,0.08)' }}><SymbolView name={icon} size={26} tintColor={dark ? '#f0f2f6' : '#273647'} /><Text style={{ position: 'absolute', width: 1, height: 1, opacity: 0 }}>{label}</Text></ExpoButton></Host></View>;
  return <View style={icon ? { alignSelf: 'flex-end' } : undefined}><Host ignoreSafeArea="all" matchContents><ExpoButton onPress={onPress} disabled={disabled} variant={variant === 'ghost' ? 'text' : 'filled'}
    style={{ borderRadius: icon ? 24 : 16, ...(icon ? { width: circle ? 44 : 42, height: circle ? 44 : 42, paddingHorizontal: 0 } : {}), backgroundColor: navigation ? (dark ? 'rgba(255,255,255,0.16)' : 'rgba(28,38,50,0.08)') : variant === 'ghost' ? 'transparent' : variant === 'prominent' || icon ? '#4d79ad' : '#e4eaf2' }}>
    {icon ? <><SymbolView name={icon} size={navigation ? 20 : 22} tintColor={navigation ? (dark ? '#f0f2f6' : '#273647') : variant === 'ghost' ? (dark ? '#d6dce5' : '#596779') : '#fff'} /><Text style={{ position: 'absolute', width: 1, height: 1, opacity: 0 }}>{label}</Text></> : <Text accessibilityLabel={label} style={{ color: variant === 'prominent' ? '#fff' : variant === 'ghost' && dark ? '#d6dce5' : '#263c59', fontSize: 14 }}>{children}</Text>}
  </ExpoButton></Host></View>;
}
