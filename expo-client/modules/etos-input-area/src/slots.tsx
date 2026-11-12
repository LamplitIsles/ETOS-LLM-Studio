import React from 'react';
import type { StyleProp, ViewProps, ViewStyle } from 'react-native';

export type InputAreaProps = Omit<ViewProps, 'children'> & {
  /** Non-secret generation that changes when the owning session is invalidated. */
  generation: number;
  composer: React.ReactNode;
  panel: React.ReactNode;
  composerStyle?: StyleProp<ViewStyle>;
  panelStyle?: StyleProp<ViewStyle>;
};

export function renderInputArea(
  Host: React.ComponentType<ViewProps>,
  Slot: React.ComponentType<ViewProps>,
  props: InputAreaProps,
) {
  const { generation, composer, panel, composerStyle, panelStyle, ...hostProps } = props;
  return (
    <Host key={generation} {...hostProps}>
      <Slot key="composer" collapsable={false} style={composerStyle}>{composer}</Slot>
      <Slot key="panel" collapsable={false} style={panelStyle}>{panel}</Slot>
    </Host>
  );
}
