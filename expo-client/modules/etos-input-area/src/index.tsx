import { View } from 'react-native';
import { renderInputArea, type InputAreaProps } from './slots';

/** Non-iOS fallback; it does not coordinate keyboard or scrolling. */
export function InputArea(props: InputAreaProps) {
  return renderInputArea(View, View, props);
}

export type { InputAreaProps } from './slots';
export { probeInputAreaTargets } from './probe';
export type { InputAreaProbeArgs, InputAreaProbeResult } from './probe-core';
export { KeyboardPanel, keyboardPanelAvailable, requestKeyboardPanel, dismissKeyboardPanel } from './keyboard-panel';
export type { KeyboardPanelProps } from './keyboard-panel';
export type { KeyboardPanelRequest, KeyboardPanelResult, KeyboardPanelDismiss } from './keyboard-panel-core';
