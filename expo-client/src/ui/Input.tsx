import React, { useEffect, useRef, useState } from 'react';
import { View, type KeyboardTypeOptions, type StyleProp, type ViewStyle } from 'react-native';
import { Host, TextInput, useNativeState } from '@expo/ui';
import { useAppearance } from './appearance';

export type InputProps = {
  value: string; onChangeText: (value: string) => void; accessibilityLabel: string;
  placeholder?: string; multiline?: boolean; editable?: boolean; onFocus?: () => void; onBlur?: () => void;
  maxLength?: number; autoCapitalize?: 'none' | 'sentences' | 'words' | 'characters'; autoCorrect?: boolean;
  keyboardType?: KeyboardTypeOptions; style?: StyleProp<ViewStyle>;
  autoFocus?: boolean; shape?: 'pill';
};

export function Input({ value, onChangeText, style, multiline, shape, ...props }: InputProps) {
  const state = useNativeState(value);
  const previous = useRef(value);
  const [height, setHeight] = useState(42);
  const { dark } = useAppearance();
  useEffect(() => {
    if (previous.current !== value) { previous.current = value; state.set(value); }
  }, [state, value]);
  return <View style={style}><Host ignoreSafeArea="all" style={{ width: '100%' }}>
    <TextInput {...props} value={state} multiline={multiline}
      onChangeText={next => { previous.current = next; onChangeText(next); }}
      onContentSizeChange={multiline ? size => setHeight(Math.max(42, Math.min(132, size.height))) : undefined}
      style={{ width: '100%', ...(multiline ? { height } : {}), ...(shape === 'pill' ? { minHeight: 44 } : {}), backgroundColor: dark ? '#30343a' : '#fff', borderRadius: shape === 'pill' ? 22 : 14, borderWidth: 0 }}
      textStyle={{ fontSize: 16, color: dark ? '#f5f6f7' : '#252832' }} />
  </Host></View>;
}
