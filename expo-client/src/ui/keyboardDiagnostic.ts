import { useCallback, useEffect, useRef, type ComponentRef, type RefObject } from 'react';
import { Keyboard, Platform, View } from 'react-native';
import type { FlashListRef } from '@shopify/flash-list';
import type { TimelineRow } from './timelineRows';

// Opt-in, development-only geometry trace. Never records text, URLs, or message IDs.
const enabled = __DEV__ && Platform.OS === 'ios' && process.env.EXPO_PUBLIC_ETOS_KEYBOARD_DIAG === '1';
type Entry = { t: number; event: string; [key: string]: number | string };
type MeasureTarget = { measureInWindow(callback: (x: number, y: number, width: number, height: number) => void): void };

export function useKeyboardDiagnostic(composer: RefObject<ComponentRef<typeof View> | null>, list: RefObject<FlashListRef<TimelineRow> | null>, latest: RefObject<ComponentRef<typeof View> | null>) {
  const run = useRef<{ started: number; entries: Entry[]; timer: ReturnType<typeof setInterval>; finish: ReturnType<typeof setTimeout> } | null>(null);
  const record = useCallback((event: string, values: Record<string, number> = {}) => {
    const trace = run.current;
    if (enabled && trace && trace.entries.length < 200) trace.entries.push({ t: Math.round(performance.now() - trace.started), event, ...values });
  }, []);
  const stop = useCallback((emit: boolean) => {
    const trace = run.current;
    if (!trace) return;
    clearInterval(trace.timer); clearTimeout(trace.finish); run.current = null;
    if (emit) console.log('[ETOS-KEYBOARD-DIAG]', JSON.stringify({ version: 1, entries: trace.entries }));
  }, []);
  const start = useCallback(() => {
    if (!enabled) return;
    stop(false);
    const trace = { started: performance.now(), entries: [] as Entry[], timer: undefined as unknown as ReturnType<typeof setInterval>, finish: undefined as unknown as ReturnType<typeof setTimeout> };
    run.current = trace;
    record('focus');
    const sample = () => {
      const capture = (event: string, target: MeasureTarget | null) => target?.measureInWindow((_x, y, _width, height) => {
        if (run.current === trace) record(event, { y: Math.round(y), height: Math.round(height) });
      });
      capture('composerFrame', composer.current);
      capture('latestFrame', latest.current);
      const target = list.current?.getNativeScrollRef() as unknown as MeasureTarget | null;
      if (typeof target?.measureInWindow === 'function') capture('listFrame', target);
    };
    sample(); trace.timer = setInterval(sample, 100); trace.finish = setTimeout(() => stop(true), 2500);
  }, [composer, list, latest, record, stop]);
  useEffect(() => {
    if (!enabled) return;
    console.log('[ETOS-KEYBOARD-DIAG]', JSON.stringify({ version: 1, event: 'ready' }));
    const listeners = (['keyboardWillShow', 'keyboardDidShow', 'keyboardWillHide', 'keyboardDidHide', 'keyboardWillChangeFrame', 'keyboardDidChangeFrame'] as const).map(event => Keyboard.addListener(event, value => {
      record(event, { height: Math.round(value.endCoordinates.height), duration: Math.round(value.duration) });
    }));
    return () => { listeners.forEach(listener => listener.remove()); stop(false); };
  }, [record, stop]);
  return { start, record };
}
