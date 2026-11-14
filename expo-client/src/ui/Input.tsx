import React, { useEffect, useRef, useState } from 'react';
import { Platform, View, type KeyboardTypeOptions, type StyleProp, type ViewStyle } from 'react-native';
import { Host, TextInput, useNativeState } from '@expo/ui';
import { useAppearance } from './appearance';

export type InputProps = {
  value: string; onChangeText: (value: string) => void; accessibilityLabel: string;
  placeholder?: string; multiline?: boolean; editable?: boolean; onFocus?: () => void; onBlur?: () => void;
  maxLength?: number; autoCapitalize?: 'none' | 'sentences' | 'words' | 'characters'; autoCorrect?: boolean;
  keyboardType?: KeyboardTypeOptions; style?: StyleProp<ViewStyle>;
  autoFocus?: boolean; shape?: 'pill';
  onSubmitEditing?: (value: string) => void; returnKeyType?: 'search' | 'done';
};

export function Input({ value, onChangeText, style, multiline, shape, autoFocus, ...props }: InputProps) {
  const state = useNativeState(value);
  const input = useRef<React.ComponentRef<typeof TextInput>>(null);
  const previous = useRef(value);
  const [height, setHeight] = useState(42);
  const { dark } = useAppearance();
  useEffect(() => {
    if (previous.current !== value) { previous.current = value; state.set(value); }
  }, [state, value]);
  // The Web sheet opens its dialog in a layout effect, after the child mounts.
  // Focus after that so the dialog's initial focus doesn't replace the input.
  useEffect(() => { if (Platform.OS === 'web' && autoFocus) void input.current?.focus(); }, [autoFocus]);
  return <View style={style}><Host ignoreSafeArea="all" style={{ width: '100%' }}>
    <TextInput {...props} ref={input} autoFocus={autoFocus} value={state} multiline={multiline}
      onChangeText={next => { previous.current = next; onChangeText(next); }}
      onContentSizeChange={multiline ? size => setHeight(Math.max(42, Math.min(132, size.height))) : undefined}
      style={{ width: '100%', ...(multiline ? { height } : {}), ...(shape === 'pill' ? { minHeight: 44 } : {}), backgroundColor: dark ? '#30343a' : '#fff', borderRadius: shape === 'pill' ? 22 : 14, borderWidth: 0 }}
      textStyle={{ fontSize: 16, color: dark ? '#f5f6f7' : '#252832' }} />
  </Host></View>;
}
