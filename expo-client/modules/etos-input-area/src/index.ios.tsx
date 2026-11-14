import { requireNativeView } from 'expo';
import { View, type ViewProps } from 'react-native';
import { renderInputArea, type InputAreaProps } from './slots';

const Host = requireNativeView<ViewProps>('ETOSInputArea');

export function InputArea(props: InputAreaProps) {
  return renderInputArea(Host, View, props);
}

export type { InputAreaProps } from './slots';
export { probeInputAreaTargets } from './probe';
export type { InputAreaProbeArgs, InputAreaProbeResult } from './probe-core';
export { KeyboardPanel, keyboardPanelAvailable, requestKeyboardPanel, dismissKeyboardPanel } from './keyboard-panel';
export type { KeyboardPanelProps } from './keyboard-panel';
export type { KeyboardPanelRequest, KeyboardPanelResult, KeyboardPanelDismiss } from './keyboard-panel-core';
