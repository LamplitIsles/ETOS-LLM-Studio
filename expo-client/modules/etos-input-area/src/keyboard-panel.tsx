import React from 'react';
import { View, type NativeSyntheticEvent, type ViewProps } from 'react-native';
import type { SequentialEvent } from './sequential-handoff-core';
import { runKeyboardPanelRequest, runKeyboardPanelDismiss, type KeyboardPanelDismiss, type KeyboardPanelRequest } from './keyboard-panel-core';

export type KeyboardPanelProps = ViewProps & { scopeGeneration: number; onSequentialHandoff?: (event: NativeSyntheticEvent<SequentialEvent>) => void };
export function keyboardPanelAvailable() { return false; }
export function KeyboardPanel({ scopeGeneration: _generation, onSequentialHandoff: _event, ...props }: KeyboardPanelProps) { return <View {...props} />; }
export function requestKeyboardPanel(args: KeyboardPanelRequest) { return runKeyboardPanelRequest(args, null); }
export function dismissKeyboardPanel(args: KeyboardPanelDismiss) { return runKeyboardPanelDismiss(args, null); }
