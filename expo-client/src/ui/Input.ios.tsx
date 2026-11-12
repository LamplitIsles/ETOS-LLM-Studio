import React, { useEffect, useRef } from 'react';
import { View } from 'react-native';
import { Host, TextInput, useNativeState } from '@expo/ui';
import { lineLimit } from '@expo/ui/swift-ui/modifiers';
import type { InputProps } from './Input';
import { useAppearance } from './appearance';

export function Input({ value, onChangeText, style, multiline, shape, ...props }: InputProps) {
  const state = useNativeState(value);
  const previous = useRef(value);
  const { dark } = useAppearance();
  useEffect(() => {
    if (previous.current !== value) { previous.current = value; state.set(value); }
  }, [state, value]);
  return <View style={[shape === 'pill' && { minHeight: 44, borderRadius: 22, backgroundColor: dark ? '#30343a' : '#fff' }, style]}><Host matchContents={{ vertical: true }} ignoreSafeArea="keyboard" style={{ width: '100%' }}>
    <TextInput {...props} value={state} multiline={multiline}
      onChangeText={next => { previous.current = next; onChangeText(next); }}
      modifiers={multiline ? [lineLimit({ min: 1, max: 6 })] : undefined}
      style={{ width: '100%', paddingHorizontal: 12, paddingVertical: 10 }}
      textStyle={{ fontSize: 16, color: dark ? '#f5f6f7' : '#252832' }} />
  </Host></View>;
}
