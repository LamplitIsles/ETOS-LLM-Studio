import React from 'react';
import { View } from 'react-native';
import { Host, Popover, RNHostView } from '@expo/ui/swift-ui';

export function StickerPopover({ shown, onDismiss, size, children, preview }: {
  shown: boolean; onDismiss: () => void; size: number; children: React.ReactElement; preview: React.ReactElement;
}) {
  return <Host style={{ width: size, height: size }} ignoreSafeArea="keyboard">
    <Popover isPresented={shown} onIsPresentedChange={visible => { if (!visible) onDismiss(); }} attachmentAnchor="top" arrowEdge="bottom">
      <Popover.Trigger><RNHostView matchContents>{children}</RNHostView></Popover.Trigger>
      <Popover.Content><RNHostView matchContents><View pointerEvents="none">{shown ? preview : null}</View></RNHostView></Popover.Content>
    </Popover>
  </Host>;
}
