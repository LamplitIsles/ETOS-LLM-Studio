import React from 'react';
import { View, type ViewProps } from 'react-native';
import { runKeyboardPanelRequest, runKeyboardPanelDismiss, type KeyboardPanelDismiss, type KeyboardPanelRequest } from './keyboard-panel-core';

export type KeyboardPanelProps = ViewProps & { scopeGeneration: number };
export function keyboardPanelAvailable() { return false; }
export function KeyboardPanel({ scopeGeneration: _generation, ...props }: KeyboardPanelProps) { return <View {...props} />; }
export function requestKeyboardPanel(args: KeyboardPanelRequest) { return runKeyboardPanelRequest(args, null); }
export function dismissKeyboardPanel(args: KeyboardPanelDismiss) { return runKeyboardPanelDismiss(args, null); }
