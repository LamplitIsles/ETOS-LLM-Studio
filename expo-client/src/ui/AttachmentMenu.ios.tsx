import React from 'react';
import { Button, Host, Image, Menu } from '@expo/ui/swift-ui';
import { accessibilityLabel, buttonStyle, disabled as disabledModifier, foregroundStyle, frame } from '@expo/ui/swift-ui/modifiers';
import type { AttachmentMenuProps } from './AttachmentMenu';

/** Use the system menu with a plain, in-field attachment icon. */
export function AttachmentMenu({ onSelect, disabled }: AttachmentMenuProps) {
  return <Host matchContents ignoreSafeArea="keyboard"><Menu label={<Image systemName="paperclip" size={22} modifiers={[foregroundStyle({ type: 'hierarchical', style: 'secondary' })]} />}
    modifiers={[buttonStyle('plain'), frame({ width: 44, height: 44 }), accessibilityLabel('附件'), disabledModifier(disabled)]}>
    <Button label="选择照片" systemImage="photo.on.rectangle" onPress={() => onSelect('image')} />
    <Button label="拍照" systemImage="camera" onPress={() => onSelect('camera')} />
    <Button label="选择文件" systemImage="doc" onPress={() => onSelect('file')} />
  </Menu></Host>;
}
