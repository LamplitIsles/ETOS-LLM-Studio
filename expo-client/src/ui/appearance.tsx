import React, { createContext, useContext, useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Appearance, Platform, useColorScheme } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';

type ColorMode = 'system' | 'light' | 'dark';
const AppearanceContext = createContext<{ dark: boolean; reduceTransparency: boolean; colorMode: ColorMode; setColorMode: (mode: ColorMode) => void }>({ dark: false, reduceTransparency: false, colorMode: 'system', setColorMode: () => {} });
const storageKey = 'etos.expo.colorMode';

export function AppearanceProvider({ children }: { children: React.ReactNode }) {
  const systemDark = useColorScheme() === 'dark';
  const [colorMode, setMode] = useState<ColorMode>('system');
  const generation = useRef(0), writes = useRef<Promise<void>>(Promise.resolve());
  const setColorMode = (mode: ColorMode) => {
    generation.current++; setMode(mode);
    writes.current = writes.current.catch(() => {}).then(() => AsyncStorage.setItem(storageKey, mode)).catch(() => {});
  };
  useEffect(() => {
    let active = true; const initial = generation.current;
    void AsyncStorage.getItem(storageKey).then(value => {
      if (active && initial === generation.current && (value === 'system' || value === 'light' || value === 'dark')) setMode(value);
    }).catch(() => {});
    return () => { active = false; };
  }, []);
  const dark = colorMode === 'system' ? systemDark : colorMode === 'dark';
  useEffect(() => {
    if (Platform.OS === 'ios') Appearance.setColorScheme(colorMode === 'system' ? 'unspecified' : colorMode);
  }, [colorMode]);
  const [reduceTransparency, setReduceTransparency] = useState(false);
  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    let active = true;
    void AccessibilityInfo.isReduceTransparencyEnabled().then(value => { if (active) setReduceTransparency(value); }).catch(() => {});
    const listener = AccessibilityInfo.addEventListener('reduceTransparencyChanged', setReduceTransparency);
    return () => { active = false; listener.remove(); };
  }, []);
  return <AppearanceContext.Provider value={{ dark, reduceTransparency, colorMode, setColorMode }}>{children}</AppearanceContext.Provider>;
}

export const useAppearance = () => useContext(AppearanceContext);
