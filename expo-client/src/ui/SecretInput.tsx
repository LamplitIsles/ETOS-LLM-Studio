import React, { useEffect, useRef } from 'react';
import { Host, TextInput, useNativeState } from '@expo/ui';

/** Keep a newly entered secret out of visible text and never populate it from a saved value. */
export function SecretInput({ value, onChange, dark, disabled, label, placeholder }: {
  value: string; onChange: (value: string) => void; dark: boolean; disabled: boolean; label: string; placeholder: string;
}) {
  const native = useNativeState(value), previous = useRef(value);
  useEffect(() => { if (previous.current !== value) { previous.current = value; native.set(value); } }, [native, value]);
  return <Host matchContents={{ vertical: true }} ignoreSafeArea="keyboard" style={{ width: '100%' }}><TextInput value={native} secureTextEntry autoCapitalize="none" autoCorrect={false} autoComplete="off"
    accessibilityLabel={label} placeholder={placeholder} editable={!disabled} maxLength={512}
    onChangeText={next => { previous.current = next; onChange(next); }} style={{ width: '100%', paddingHorizontal: 12, paddingVertical: 10, backgroundColor: dark ? '#30343a' : '#fff', borderRadius: 14 }}
    textStyle={{ fontSize: 16, color: dark ? '#f5f6f7' : '#252832' }} /></Host>;
}
