import React from 'react';
import { View, type ViewStyle } from 'react-native';

const maskStyle = {
  flex: 1,
  maskImage: 'linear-gradient(to bottom, transparent 0px, black 20px, black calc(100% - 20px), transparent 100%)',
} as ViewStyle;

export function TimelineViewport({ children }: { children: React.ReactNode }) {
  return <View testID="timeline-mask" style={maskStyle}>{children}</View>;
}
