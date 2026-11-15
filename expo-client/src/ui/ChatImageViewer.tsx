import React, { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Image, Platform, Pressable, ScrollView, Text, View, useWindowDimensions } from 'react-native';
import { RNHostView } from '@expo/ui';
import type { ChatController } from '../cfl/chat';
import type { ApiTransport } from '../cfl/transport';
import { Button } from './Button';
import { FullSheet } from './FullSheet';
import { useAppearance } from './appearance';
import type { ImageViewerTarget } from './chatImageGallery';

function useViewerImage(target: ImageViewerTarget, controller: ChatController, media: ApiTransport, thumbnail: boolean) {
  const [image, setImage] = useState<{ key: string; uri: string | null; failed: boolean }>({ key: target.key, uri: target.localUri ?? null, failed: false });
  useEffect(() => {
    if (target.localUri) { setImage({ key: target.key, uri: target.localUri, failed: false }); return; }
    const current = controller.scope(), abort = new AbortController();
    let active = true;
    setImage({ key: target.key, uri: null, failed: false });
    const variant = thumbnail ? 'preview' : 'original';
    void controller.readImage(media, target.id, () => active && current(), variant, abort.signal).then(result => {
      if (!active || !current()) return;
      let binary = '';
      for (let i = 0; i < result.bytes.length; i += 8192) binary += String.fromCharCode(...result.bytes.subarray(i, i + 8192));
      setImage({ key: target.key, uri: `data:${result.contentType};base64,${btoa(binary)}`, failed: false });
    }).catch(() => { if (active && current()) setImage({ key: target.key, uri: null, failed: true }); });
    return () => { active = false; abort.abort(); };
  }, [controller, media, target.id, target.key, target.localUri, thumbnail]);
  return image.key === target.key ? image : { uri: null, failed: false };
}

function PhotoPage({ target, controller, media, width, height, dark, active }: { target: ImageViewerTarget; controller: ChatController; media: ApiTransport; width: number; height: number; dark: boolean; active: boolean }) {
  const image = useViewerImage(target, controller, media, false);
  return <View style={{ width, flex: 1 }} accessibilityElementsHidden={!active} importantForAccessibility={active ? 'auto' : 'no-hide-descendants'}>
    {image.uri ? <ScrollView key={target.key} style={{ flex: 1 }} contentContainerStyle={{ flexGrow: 1, alignItems: 'center', justifyContent: 'center' }} minimumZoomScale={1} maximumZoomScale={4} centerContent>
      <Image accessibilityLabel="图片原图" source={{ uri: image.uri }} resizeMode="contain" style={{ width, height }} />
    </ScrollView> : <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>{image.failed ? <Text style={{ color: dark ? '#f4f4f6' : '#252631' }}>图片暂时无法显示</Text> : <ActivityIndicator color={dark ? '#f4f4f6' : '#252631'} />}</View>}
  </View>;
}

function PhotoThumbnail({ target, controller, media, selected, index, onSelect }: { target: ImageViewerTarget; controller: ChatController; media: ApiTransport; selected: boolean; index: number; onSelect: () => void }) {
  const image = useViewerImage(target, controller, media, true);
  return <Pressable accessibilityRole="button" accessibilityLabel={`查看第 ${index + 1} 张图片`} accessibilityState={{ selected }} aria-pressed={selected} onPress={onSelect} style={{ width: 48, height: 48, padding: 2, borderRadius: 8, borderWidth: 2, borderColor: selected ? '#4d79ad' : 'transparent' }}>
    {image.uri ? <Image source={{ uri: image.uri }} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" resizeMode="cover" style={{ width: 40, height: 40, borderRadius: 4 }} /> : <View style={{ width: 40, height: 40, borderRadius: 4, backgroundColor: '#8d929a' }} />}
  </Pressable>;
}

export function ChatImageViewer({ target, items, controller, media, onClose, onNavigate }: {
  target: ImageViewerTarget; items: ImageViewerTarget[]; controller: ChatController; media: ApiTransport; onClose: () => void; onNavigate: (target: ImageViewerTarget) => void;
}) {
  const [open, setOpen] = useState(true);
  const [viewportHeight, setViewportHeight] = useState(0);
  const pager = useRef<FlatList<ImageViewerTarget>>(null);
  const thumbnails = useRef<FlatList<ImageViewerTarget>>(null);
  const webScrollTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const { width: windowWidth, height } = useWindowDimensions();
  const { dark } = useAppearance();
  const width = Math.max(1, windowWidth - 32);
  const selectedIndex = Math.max(0, items.findIndex(item => item.key === target.key));
  const showThumbnails = items.length > 1;
  const getPageLayout = useCallback((_: ArrayLike<ImageViewerTarget> | null | undefined, index: number) => ({ length: width, offset: width * index, index }), [width]);
  const getThumbLayout = useCallback((_: ArrayLike<ImageViewerTarget> | null | undefined, index: number) => ({ length: 52, offset: 52 * index, index }), []);
  useEffect(() => () => { if (webScrollTimer.current) clearTimeout(webScrollTimer.current); webScrollTimer.current = null; }, [target.key, items, width]);
  const selectPage = (offset: number) => {
    const index = Math.min(items.length - 1, Math.max(0, Math.round(offset / width)));
    const item = items[index];
    if (item && item.key !== target.key) onNavigate(item);
    else if (Platform.OS === 'web' && Math.abs(offset - index * width) > 1) pager.current?.scrollToIndex({ index, animated: true });
  };
  useEffect(() => {
    pager.current?.scrollToIndex({ index: selectedIndex, animated: false });
    thumbnails.current?.scrollToIndex({ index: selectedIndex, animated: true, viewPosition: 0.5 });
  }, [selectedIndex, width]);
  return <FullSheet open={open} onRequestClose={() => setOpen(false)} onDismiss={onClose} nativeGlass color={dark ? '#30343a' : '#f4f5f7'} testID="chat-image-viewer">
    <RNHostView><View style={{ flex: 1 }} onLayout={event => setViewportHeight(event.nativeEvent.layout.height)}>
      <View style={{ alignItems: 'flex-end' }}><Button size="navigation" accessibilityLabel="关闭图片" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={() => setOpen(false)} /></View>
      <FlatList ref={pager} testID="chat-image-pager" style={{ flex: 1 }} data={items} horizontal pagingEnabled showsHorizontalScrollIndicator={false} keyExtractor={item => item.key}
        initialScrollIndex={selectedIndex} getItemLayout={getPageLayout} windowSize={3} initialNumToRender={3} maxToRenderPerBatch={3}
        scrollEventThrottle={16} onMomentumScrollEnd={event => selectPage(event.nativeEvent.contentOffset.x)}
        onScroll={Platform.OS === 'web' ? event => { const offset = event.nativeEvent.contentOffset.x; if (webScrollTimer.current) clearTimeout(webScrollTimer.current); webScrollTimer.current = setTimeout(() => { webScrollTimer.current = null; selectPage(offset); }, 160); } : undefined}
        renderItem={({ item }) => <PhotoPage target={item} controller={controller} media={media} width={width} height={Math.max(1, (viewportHeight || height - 180) - (showThumbnails ? 108 : 44))} dark={dark} active={item.key === target.key} />} />
      {showThumbnails && <FlatList ref={thumbnails} testID="chat-image-thumbnails" style={{ flexGrow: 0, height: 64 }} contentContainerStyle={{ alignItems: 'center', gap: 4, paddingHorizontal: Math.max(0, (width - items.length * 52 + 4) / 2) }} data={items} horizontal showsHorizontalScrollIndicator={false}
        keyExtractor={item => item.key} getItemLayout={getThumbLayout} windowSize={3} initialNumToRender={7} maxToRenderPerBatch={7}
        renderItem={({ item, index }) => <PhotoThumbnail target={item} controller={controller} media={media} selected={item.key === target.key} index={index} onSelect={() => { if (item.key !== target.key) onNavigate(item); }} />} />}
    </View></RNHostView>
  </FullSheet>;
}
