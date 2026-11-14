import React from 'react';
import { requireNativeView, requireOptionalNativeModule } from 'expo';
import type { ViewProps } from 'react-native';
import { runKeyboardPanelRequest, runKeyboardPanelDismiss, type KeyboardPanelDismiss, type KeyboardPanelNative, type KeyboardPanelRequest } from './keyboard-panel-core';
export type KeyboardPanelProps = ViewProps & { scopeGeneration: number };
let NativePanel: React.ComponentType<KeyboardPanelProps> | undefined;

export function keyboardPanelAvailable() {
  const module = requireOptionalNativeModule<KeyboardPanelNative>('ETOSInputArea');
  return typeof module?.requestKeyboardPanel === 'function' && typeof module?.dismissKeyboardPanel === 'function';
}

/** Only render after keyboardPanelAvailable() succeeds in the current binary. */
export function KeyboardPanel(props: KeyboardPanelProps) {
  NativePanel ??= requireNativeView<KeyboardPanelProps>('ETOSInputArea', 'KeyboardPanel');
  return <NativePanel {...props} />;
}

export function requestKeyboardPanel(args: KeyboardPanelRequest) {
  return runKeyboardPanelRequest(args, requireOptionalNativeModule<KeyboardPanelNative>('ETOSInputArea'));
}

export function dismissKeyboardPanel(args: KeyboardPanelDismiss) {
  return runKeyboardPanelDismiss(args, requireOptionalNativeModule<KeyboardPanelNative>('ETOSInputArea'));
}
