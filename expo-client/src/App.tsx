import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Image, Keyboard, Linking, Platform, ScrollView, StyleSheet, Text, TextInput, View, findNodeHandle, useWindowDimensions, type ScrollViewProps } from 'react-native';
import { EnrichedMarkdownText, type MarkdownStyle } from 'react-native-enriched-markdown';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { KeyboardAvoidingView, KeyboardChatScrollView, KeyboardProvider, KeyboardStickyView, useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import Animated, { ReduceMotion, useAnimatedReaction, useAnimatedStyle, useDerivedValue, useSharedValue, withTiming, type SharedValue } from 'react-native-reanimated';
import { BottomSheet, RNHostView } from '@expo/ui';
import { SymbolView } from 'expo-symbols';
import { requireOptionalNativeModule } from 'expo';
import { FlashList, type FlashListRef } from '@shopify/flash-list';
import type { ChatMessage } from '../vendor/contracts/src/index';
import type { StickerIdentity } from '../vendor/contracts/src/index';
import { createDevelopmentSeedChat, developmentSeedAvailable, developmentSeedStatus } from './cfl/seed.web';
import { type ChatController, type ChatSnapshot } from './cfl/chat';
import { createNativeAuth } from './cfl/native-runtime';
import { createNativeChat } from './cfl/factory.native';
import { createWebChat } from './cfl/factory.web';
import { WebAuth } from './cfl/web-auth';
import { loadAppearance, loadAppearanceImage } from './cfl/appearance';
import { type ImageData, type ApiTransport } from './cfl/transport';
import { recentStickers } from './cfl/recent-stickers';
import { classifyMarkdownImage, loadMarkdownImage } from './cfl/markdown-image';
import { createMarkdownImageUri } from './cfl/markdown-image-uri';
import { markdownImageResolverAvailable } from './cfl/markdown-resolver';
import { CameraPermissionError, capturePhoto, pickFiles, pickImages, type AttachmentDraft } from './cfl/drafts';
import { CameraPhotoError, prepareCameraPhoto } from './cfl/camera-photo';
import { validateDrafts } from './cfl/intake';
import { sendDrafts, sendSticker, type SendOutcome } from './cfl/composer';
import { StickerPanel } from './StickerPanel';
import { NativeTabsFrame } from './NativeTabsFrame';
import { AppearanceProvider, useAppearance } from './ui/appearance';
import { Surface } from './ui/Surface';
import { Button } from './ui/Button';
import { Input } from './ui/Input';
import { TimelineViewport } from './ui/TimelineScrollView';
import { captureHistoryAnchor } from './ui/historyAnchor';
import { rowsFor, type TimelineRow as Row } from './ui/timelineRows';
import { attachmentValidationMessage, cameraPhotoMessage } from './ui/attachmentValidationMessage';
import { ReminderButton } from './ui/ReminderButton';
import { ChatSearch } from './ui/ChatSearch';
import { ChatSettings } from './ui/ChatSettings';
import { useKeyboardDiagnostic } from './ui/keyboardDiagnostic';
import type { InputAreaProps } from '../modules/etos-input-area/src';
import type { InputAreaProbeArgs, InputAreaProbeResult } from '../modules/etos-input-area/src/probe-core';
import type { KeyboardPanelProps } from '../modules/etos-input-area/src/keyboard-panel';
import type { KeyboardPanelDismiss, KeyboardPanelRequest, KeyboardPanelResult } from '../modules/etos-input-area/src/keyboard-panel-core';

// An older development binary cannot load a newly added native view. Keep its
// existing input usable until the new binary is installed.
const inputAreaModule: { InputArea: React.ComponentType<InputAreaProps>; probeInputAreaTargets: (args: InputAreaProbeArgs) => Promise<InputAreaProbeResult>; KeyboardPanel: React.ComponentType<KeyboardPanelProps>; keyboardPanelAvailable: () => boolean; requestKeyboardPanel: (args: KeyboardPanelRequest) => Promise<KeyboardPanelResult>; dismissKeyboardPanel: (args: KeyboardPanelDismiss) => Promise<KeyboardPanelResult> } | null = Platform.OS !== 'ios' || requireOptionalNativeModule('ETOSInputArea')
  ? require('../modules/etos-input-area/src')
  : null;
const InputArea: React.ComponentType<InputAreaProps> = inputAreaModule?.InputArea
  ?? (({ generation, composer, panel, style, composerStyle, panelStyle }) => <View key={generation} style={style}><View style={composerStyle}>{composer}</View><View style={panelStyle}>{panel}</View></View>);

type Client = { controller: ChatController; media: ApiTransport };
type Mode = 'seed' | 'native' | 'web';
type AppearanceView = { client: Client; sessionId: string; name: string; avatar?: string; portrait?: string; landscape?: string };

function AuthImage({ id, media, controller, mediaType, sticker = false }: { id: string; media: ApiTransport; controller: ChatController; mediaType: string; sticker?: boolean }) {
  const [value, setValue] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let active = true;
    const abort = new AbortController();
    setValue(null); setFailed(false);
    const current = controller.scope();
    // JPEG previews are opaque; formats that can carry transparency or animation
    // need the original attachment rather than a converted preview.
    void controller.readImage(media, id, () => active && current(), sticker || mediaType !== 'image/jpeg' ? 'original' : 'preview', abort.signal).then(({ bytes, contentType }) => {
      if (!active || !current()) return;
      let binary = '';
      for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
      setValue(`data:${contentType};base64,${btoa(binary)}`);
    }).catch(() => { if (active && current()) setFailed(true); });
    return () => { active = false; abort.abort(); };
  }, [id, media, controller, mediaType, sticker]);
  if (failed) return <Text style={styles.mediaNotice}>图片暂时无法显示</Text>;
  if (!value) return <View style={styles.imageLoading}><ActivityIndicator /><Text style={styles.mediaNotice}>图片加载中</Text></View>;
  return <Image source={{ uri: value }} accessibilityLabel={sticker ? '表情图片' : '聊天图片'} resizeMode="contain" style={sticker ? styles.stickerImage : styles.image} />;
}

function imageUri(image: ImageData, createdUrls: string[]): string {
  if (Platform.OS === 'web') {
    const url = URL.createObjectURL(new Blob([new Uint8Array(image.bytes).buffer], { type: image.contentType }));
    createdUrls.push(url);
    return url;
  }
  let binary = '';
  for (let i = 0; i < image.bytes.length; i += 8192) binary += String.fromCharCode(...image.bytes.subarray(i, i + 8192));
  return `data:${image.contentType};base64,${btoa(binary)}`;
}

// An older native build without the parser cannot intercept embedded media.
const embeddedMedia = /!\[|<\s*\/?\s*(?:img|video|source|audio|iframe)\b/i;

function MessageText({ text, foreground, dark, media, controller, workspaceImages }: {
  text: string; foreground: string; dark: boolean; media: ApiTransport; controller: ChatController; workspaceImages: boolean;
}) {
  const [resolveImage, setResolveImage] = useState<null | ((image: { url: string }) => Promise<{ uri: string }>)>(null);
  const resolverAvailable = markdownImageResolverAvailable();
  useEffect(() => {
    if (!resolverAvailable) return;
    let active = true;
    const scope = controller.scope();
    const abort = new AbortController();
    const releases = new Set<() => void>();
    const current = () => active && scope();
    const resolve = async ({ url }: { url: string }): Promise<{ uri: string }> => {
      try {
        const options = { workspaceImages, isCurrent: current, signal: abort.signal };
        const source = classifyMarkdownImage(url, media.origin, options);
        // A browser image can display cross-origin resources even when the
        // image server does not grant JavaScript CORS access.
        if (Platform.OS === 'web' && source.kind === 'external') return { uri: source.url };
        const image = await loadMarkdownImage(url, media, options);
        const result = await createMarkdownImageUri(image, current, abort.signal);
        if (!current()) { result.release(); return { uri: '' }; }
        releases.add(result.release);
        return { uri: result.uri };
      } catch { return { uri: '' }; }
    };
    setResolveImage(() => resolve);
    return () => { active = false; abort.abort(); for (const release of releases) release(); };
  }, [controller, media, workspaceImages, resolverAvailable]);
  const markdownStyle = useMemo<MarkdownStyle>(() => {
    const block = { color: foreground, fontSize: 16, lineHeight: 23 };
    const subtle = dark ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,45,0.08)';
    return {
      paragraph: { ...block, marginBottom: 8 },
      h1: { ...block, fontSize: 23, lineHeight: 30, fontWeight: 'bold' },
      h2: { ...block, fontSize: 21, lineHeight: 28, fontWeight: 'bold' },
      h3: { ...block, fontSize: 19, lineHeight: 26, fontWeight: 'bold' },
      h4: { ...block, fontWeight: 'bold' }, h5: { ...block, fontWeight: 'bold' }, h6: { ...block, fontWeight: 'bold' },
      list: { ...block, bulletColor: foreground, markerColor: foreground, marginBottom: 8 },
      blockquote: { ...block, borderColor: foreground, backgroundColor: subtle, marginBottom: 8 },
      codeBlock: { color: dark ? '#f4f4f6' : '#252631', backgroundColor: dark ? '#30363d' : '#e5e8ed', borderRadius: 10, fontSize: 14, marginBottom: 8 },
      code: { color: foreground, backgroundColor: subtle },
      link: { color: foreground, underline: true },
      table: { ...block, headerTextColor: foreground, headerBackgroundColor: subtle, rowEvenBackgroundColor: 'transparent', rowOddBackgroundColor: subtle },
      math: { color: foreground, backgroundColor: 'transparent', fontSize: 18, padding: 0, marginBottom: 8 },
      inlineMath: { color: foreground },
      image: { maxHeight: 240, resizeMode: 'contain', borderRadius: 12 },
      inlineImage: { size: 72 },
    };
  }, [foreground, dark]);
  const openLink = useCallback(({ url }: { url: string }) => {
    try {
      const parsed = new URL(url);
      if (parsed.protocol === 'https:' || parsed.protocol === 'http:') void Linking.openURL(parsed.href).catch(() => {});
    } catch { /* Unsupported or relative links are not opened. */ }
  }, []);
  if (!resolverAvailable && embeddedMedia.test(text)) return <Text selectable style={[styles.messageText, { color: foreground }]}>{text}</Text>;
  if (resolverAvailable && !resolveImage) return null;
  return <EnrichedMarkdownText markdown={text} flavor="github" markdownStyle={markdownStyle}
    md4cFlags={{ hardSoftBreaks: true }} selectable enableTaskListItemToggle={false}
    enableLinkPreview={false} onLinkPress={openLink}
    {...(resolveImage ? { resolveImageSource: resolveImage, renderers: { video: () => <Text style={{ color: foreground }}>视频暂不支持显示</Text> } } : {})} />;
}

function MessageBubble({ row, media, controller, sessionId, workspaceImages, latestRef }: { row: Row; media: ApiTransport; controller: ChatController; sessionId: string; workspaceImages: boolean; latestRef?: React.RefObject<React.ComponentRef<typeof View> | null> }) {
  const { dark } = useAppearance();
  const mine = row.user._id === 'me';
  const item = row.original;
  const foreground = mine ? '#ffffff' : dark ? '#f4f4f6' : '#252631';
  const placeholderStyle = [styles.contentPlaceholder, { color: dark ? '#e3e7ec' : '#4d5561', backgroundColor: dark ? 'rgba(38,43,51,0.94)' : 'rgba(247,248,250,0.94)' }];
  const hasImage = item?.images?.some(image => !image.sticker);
  return <View ref={latestRef} nativeID={`timeline-${row._id}`} testID={mine ? 'message-user' : 'message-agent'} style={[styles.messageRow, mine ? styles.mine : styles.theirs]}>
    {item?.source?.kind === 'reminder' && row.text ? <ReminderButton text={row.text} /> : (row.text || row.pendingState === 'failed') ? <Surface tint={mine ? '#536d94' : undefined} style={[styles.bubble, mine && styles.myBubble]}>
      {!!row.text && <MessageText key={`${media.origin}:${sessionId}:${workspaceImages}`} text={row.text} foreground={foreground} dark={mine || dark} media={media} controller={controller} workspaceImages={workspaceImages} />}
      {row.pendingState === 'failed' && <Text style={styles.errorSmall}>发送失败，请检查连接</Text>}
    </Surface> : null}
    {hasImage && item?.images?.filter(image => !image.sticker).map(image => <AuthImage key={image.attachmentId} id={image.attachmentId} media={media} controller={controller} mediaType={image.mediaType} />)}
    {item?.images?.filter(image => image.sticker).map(image => <AuthImage key={image.attachmentId} id={image.attachmentId} media={media} controller={controller} mediaType={image.mediaType} sticker />)}
    {item?.files?.map(file => <Text key={file.attachmentId} numberOfLines={1} style={placeholderStyle}>文件 · {file.name}</Text>)}
    {row.pendingImages?.map(image => <AuthImage key={image.attachmentId} id={image.attachmentId} media={media} controller={controller} mediaType={image.mediaType} sticker={!!image.sticker} />)}
    {row.pendingFiles?.map(file => <Text key={file.attachmentId} numberOfLines={1} style={placeholderStyle}>文件 · {file.name}</Text>)}
    {item?.ui != null && <Text style={placeholderStyle}>互动卡片 · 暂不支持显示</Text>}
    {item?.voice && <Text style={placeholderStyle}>语音消息 · 暂不支持播放</Text>}
    {item?.imageState && !item.images?.length && <Text style={placeholderStyle}>图片暂时不可用</Text>}
  </View>;
}

function EmojiPanel({ open, children, panelHeight, visibleHeight, progress, instantOpen }: { open: boolean; children: React.ReactNode; panelHeight: number; visibleHeight: SharedValue<number>; progress: SharedValue<number>; instantOpen: boolean }) {
  const [mounted, setMounted] = useState(open);
  useEffect(() => {
    if (open) setMounted(true);
    progress.value = open && instantOpen && Platform.OS === 'ios' ? 1 : withTiming(open ? 1 : 0, { duration: open ? 180 : 100, reduceMotion: ReduceMotion.System });
    if (!open) {
      const timeout = setTimeout(() => setMounted(false), 100);
      return () => clearTimeout(timeout);
    }
  }, [open, instantOpen, progress]);
  const panelStyle = useAnimatedStyle(() => ({ height: Platform.OS === 'ios' ? visibleHeight.value : 300 * progress.value, overflow: Platform.OS === 'ios' ? 'visible' : 'hidden' }));
  if (!mounted) return null;
  return <Animated.View style={panelStyle} pointerEvents={open ? 'auto' : 'none'} accessibilityElementsHidden={!open} importantForAccessibility={open ? 'auto' : 'no-hide-descendants'}>{Platform.OS === 'ios' ? <View style={{ position: 'absolute', top: 0, left: 0, right: 0, height: panelHeight }}>{children}</View> : children}</Animated.View>;
}

function AttachmentPanel({ dark, onSelect, onClose }: { dark: boolean; onSelect: (kind: 'image' | 'camera' | 'file') => void; onClose: () => void }) {
  const actions = [
    { kind: 'image' as const, label: '照片', accessibilityLabel: '选择照片', icon: { ios: 'photo.on.rectangle', web: 'photo_library', android: 'photo_library' }, disabled: false },
    { kind: 'camera' as const, label: '拍摄', accessibilityLabel: '拍照', icon: { ios: 'camera', web: 'photo_camera', android: 'photo_camera' }, disabled: Platform.OS !== 'ios' },
    { kind: 'file' as const, label: '文件', accessibilityLabel: '选择文件', icon: { ios: 'doc', web: 'description', android: 'description' }, disabled: false },
  ] as const;
  return <View testID="attachments-panel" style={styles.attachmentPanel}>
    <View style={styles.attachmentHeading}><Text style={[styles.attachmentTitle, { color: dark ? '#f5f6f7' : '#252832' }]}>附件</Text><Button accessibilityLabel="关闭附件" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
    <View style={styles.attachmentActions}>{actions.map(action => <View key={action.label} style={styles.attachmentAction}>
      <Button size="attachment" accessibilityLabel={action.accessibilityLabel} icon={action.icon} disabled={action.disabled} onPress={() => onSelect(action.kind)} />
      <Text style={[styles.attachmentActionLabel, { color: dark ? '#e8ebef' : '#394454', opacity: action.disabled ? 0.55 : 1 }]}>{action.label}</Text>
    </View>)}</View>
  </View>;
}

function AppContent() {
  const { dark } = useAppearance();
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const [client, setClient] = useState<Client | null>(null);
  const [mode, setMode] = useState<Mode | null>(null);
  const [restoring, setRestoring] = useState(true);
  const [snapshot, setSnapshot] = useState<ChatSnapshot | null>(null);
  const [spaceOpen, setSpaceOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [contextOpen, setContextOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [draft, setDraft] = useState('');
  const [inputHeight, setInputHeight] = useState(44);
  const [toolbarHeight, setToolbarHeight] = useState(72);
  const [emojiOpen, setEmojiOpen] = useState(false);
  const emojiOpenRef = useRef(false); emojiOpenRef.current = emojiOpen;
  const [panelKind, setPanelKind] = useState<'stickers' | 'attachments'>('stickers');
  const [panelVersion, setPanelVersion] = useState(0);
  const [inputAreaReset, setInputAreaReset] = useState(0);
  const panelRevision = useRef(0);
  const desiredPanelKind = useRef<'stickers' | 'attachments'>('stickers');
  const [emojiPanelHeight, setEmojiPanelHeight] = useState(300);
  const [emojiInstantOpen, setEmojiInstantOpen] = useState(false);
  const waitingForComposerKeyboard = useRef(false);
  const [stickerSearchActive, setStickerSearchActive] = useState(false);
  const [showScrollToBottom, setShowScrollToBottom] = useState(false);
  const inputRef = useRef<React.ComponentRef<typeof TextInput> | null>(null);
  const messagesRef = useRef<FlashListRef<Row>>(null);
  const composerRef = useRef<React.ComponentRef<typeof View> | null>(null);
  const latestRef = useRef<React.ComponentRef<typeof View> | null>(null);
  const keyboardDiagnostic = useKeyboardDiagnostic(composerRef, messagesRef, latestRef);
  // The chat scroll view owns keyboard insets; the sticky composer moves with the keyboard.
  const iosChatKeyboard = Platform.OS === 'ios';
  const nativePanelAvailable = iosChatKeyboard && !!inputAreaModule?.keyboardPanelAvailable();
  const panelTag = useRef<number | null>(null);
  const panelTagGeneration = useRef(0);
  const panelGeneration = useRef(0);
  const nativePanelMode = useRef<'closed' | 'keyboard' | 'panel'>('closed');
  const panelRequestSequence = useRef(0);
  const nativePanelAction = useRef<(mode: 'panel' | 'keyboard' | 'dismiss') => Promise<KeyboardPanelResult>>(async () => ({ status: 'unavailable' }));
  const nativePanelBusy = useRef(false);
  const nativePanelUnknown = useRef(false);
  const [panelBusy, setPanelBusy] = useState(false);
  const pendingPanelOpen = useRef<'stickers' | 'attachments' | null>(null);
  const laidOutPanel = useRef<{ kind: 'stickers' | 'attachments'; generation: number; revision: number } | null>(null);
  const presentPendingPanel = useRef<() => void>(() => {});
  const searchBlur = useRef<null | { observed: boolean }>(null);
  const chatContentInset = useSharedValue(92);
  const chatComposerHeight = useSharedValue(72);
  const chatKeyboardFrozen = useSharedValue(false);
  const emojiProgress = useSharedValue(0);
  const keyboard = useReanimatedKeyboardAnimation();
  const nativeStickyOffset = useSharedValue(0);
  useAnimatedReaction(
    () => ({ height: keyboard.height.value, frozen: chatKeyboardFrozen.value }),
    value => { if (nativePanelAvailable && !value.frozen) nativeStickyOffset.value = value.height; },
    [nativePanelAvailable],
  );
  const nativeStickyStyle = useAnimatedStyle(() => ({ transform: [{ translateY: nativeStickyOffset.value }] }));
  const emojiVisibleHeight = useDerivedValue(() => Math.max(0, emojiPanelHeight * emojiProgress.value - (stickerSearchActive ? 0 : Math.max(0, -keyboard.height.value))), [emojiPanelHeight, stickerSearchActive]);
  useAnimatedReaction(
    () => ({ frozen: chatKeyboardFrozen.value, height: chatComposerHeight.value + (nativePanelAvailable ? 0 : emojiVisibleHeight.value) + 20 }),
    value => { if (iosChatKeyboard && !value.frozen) chatContentInset.value = value.height; },
    [iosChatKeyboard, nativePanelAvailable],
  );
  const switchingKeyboard = useRef(false);
  const toolbarHeightRef = useRef(toolbarHeight);
  const waitingForSearchKeyboard = useRef(false);
  const restoringPanelAfterSearch = useRef(false);
  const searchHandoffEpoch = useRef(0);
  const stickerSearchActiveRef = useRef(false);
  const timelineTouch = useRef<{ x: number; y: number; started: number } | null>(null);
  const clearSearchHandoff = useCallback(() => {
    searchHandoffEpoch.current++; waitingForSearchKeyboard.current = false; restoringPanelAfterSearch.current = false;
    stickerSearchActiveRef.current = false; setStickerSearchActive(false); chatKeyboardFrozen.value = false; setPanelBusy(nativePanelBusy.current);
  }, [chatKeyboardFrozen]);
  const closeEmojiPanel = useCallback((afterClose?: () => void) => {
    if (searchBlur.current || restoringPanelAfterSearch.current) return;
    if (pendingPanelOpen.current && !nativePanelBusy.current) { pendingPanelOpen.current = null; setEmojiOpen(false); afterClose?.(); return; }
    if (nativePanelAvailable && nativePanelMode.current === 'panel') {
      if (nativePanelBusy.current || nativePanelUnknown.current) return;
      const generation = panelGeneration.current;
      void nativePanelAction.current('dismiss').then(result => {
        if (generation !== panelGeneration.current) return;
        if (result.status !== 'requested') return;
        nativePanelMode.current = 'closed';
        clearSearchHandoff(); setEmojiOpen(false); afterClose?.();
      });
      return;
    }
    if (nativePanelBusy.current || nativePanelUnknown.current) return;
    clearSearchHandoff(); waitingForComposerKeyboard.current = false; switchingKeyboard.current = false;
    setEmojiOpen(false); afterClose?.();
  }, [clearSearchHandoff, nativePanelAvailable]);
  const openComposerPanel = (kind: 'stickers' | 'attachments') => {
    if (nativePanelAvailable && (nativePanelBusy.current || nativePanelUnknown.current || pendingPanelOpen.current || searchBlur.current || restoringPanelAfterSearch.current)) return;
    if (desiredPanelKind.current !== kind) { desiredPanelKind.current = kind; setPanelVersion(++panelRevision.current); }
    if (nativePanelAvailable && emojiOpen && nativePanelMode.current === 'panel' && inputRef.current?.isFocused()) { setPanelKind(kind); return; }
    setPanelKind(kind);
    if (nativePanelAvailable) {
      pendingPanelOpen.current = kind;
      setEmojiOpen(true);
      presentPendingPanel.current();
      return;
    }
    if (emojiOpen) return;
    const keyboardVisible = iosChatKeyboard && Keyboard.isVisible();
    if (keyboardVisible) { switchingKeyboard.current = true; chatKeyboardFrozen.value = true; }
    setEmojiInstantOpen(keyboardVisible);
    setEmojiOpen(true);
    Keyboard.dismiss();
  };
  presentPendingPanel.current = () => {
    const kind = pendingPanelOpen.current, layout = laidOutPanel.current, generation = panelGeneration.current;
    if (!nativePanelAvailable || !kind || !layout || layout.kind !== kind || layout.generation !== generation || layout.revision !== panelRevision.current ||
        panelTagGeneration.current !== generation || hostTagGeneration.current !== generation || !panelTag.current || !inputAreaHostTag.current) return;
    pendingPanelOpen.current = null;
    const previous = nativePanelMode.current;
    nativePanelMode.current = 'panel';
    void nativePanelAction.current('panel').then(result => {
      if (generation !== panelGeneration.current || result.status === 'requested') return;
      if (result.status !== 'unavailable' && result.status !== 'invalid_response' && result.status !== 'session_changed') {
        nativePanelMode.current = previous; setEmojiOpen(previous === 'panel');
      }
    });
  };
  const openSystemKeyboard = () => {
    if (nativePanelBusy.current || nativePanelUnknown.current || searchBlur.current || restoringPanelAfterSearch.current) return;
    const generation = panelGeneration.current;
    void nativePanelAction.current('keyboard').then(result => {
      if (generation !== panelGeneration.current) return;
      if (result.status === 'requested') { nativePanelMode.current = 'keyboard'; setEmojiOpen(false); }
    });
  };
  const restorePanelAfterSearch = useCallback(() => {
    if (!nativePanelAvailable || nativePanelBusy.current || nativePanelUnknown.current) { clearSearchHandoff(); return; }
    restoringPanelAfterSearch.current = true; setPanelBusy(true);
    const generation = panelGeneration.current, handoff = ++searchHandoffEpoch.current;
    nativePanelMode.current = 'panel';
    void nativePanelAction.current('panel').then(async result => {
      if (generation !== panelGeneration.current || handoff !== searchHandoffEpoch.current) return;
      if (result.status !== 'requested') { if (result.status !== 'unavailable' && result.status !== 'invalid_response' && result.status !== 'session_changed') { nativePanelMode.current = 'closed'; setEmojiOpen(false); } clearSearchHandoff(); return; }
      // An RN focus callback can arrive before the native acknowledgement.
      if (inputRef.current?.isFocused() || !restoringPanelAfterSearch.current) { clearSearchHandoff(); return; }
      const hostTag = inputAreaHostTag.current, inputTag = findNodeHandle(inputRef.current), scrollTag = messagesRef.current?.getScrollableNode();
      const scope = client?.controller.scope();
      const current = () => generation === panelGeneration.current && !!client && active.current === client && !!scope?.() && handoff === searchHandoffEpoch.current && restoringPanelAfterSearch.current;
      if (inputAreaModule && hostTag && inputTag && typeof scrollTag === 'number' && current()) {
        const observed = await inputAreaModule.probeInputAreaTargets({ hostTag, inputTag, scrollTag, current });
        if (generation !== panelGeneration.current || handoff !== searchHandoffEpoch.current || !restoringPanelAfterSearch.current) return;
        if (observed.status === 'observed' && observed.inputFocused) { clearSearchHandoff(); return; }
      }
      if (generation === panelGeneration.current && handoff === searchHandoffEpoch.current && restoringPanelAfterSearch.current) {
        nativePanelUnknown.current = true; clearSearchHandoff(); setError('面板状态暂时无法确认，请重启应用后重试。');
      }
    });
  }, [clearSearchHandoff, nativePanelAvailable, client]);
  const onStickerSearchVisibilityChange = useCallback((visible: boolean) => {
    if (visible) { searchHandoffEpoch.current++; stickerSearchActiveRef.current = true; waitingForSearchKeyboard.current = false; restoringPanelAfterSearch.current = false; chatKeyboardFrozen.value = true; setStickerSearchActive(true); }
    else if (!stickerSearchActiveRef.current || waitingForSearchKeyboard.current || restoringPanelAfterSearch.current) return;
    else if (nativePanelAvailable && emojiOpenRef.current) restorePanelAfterSearch();
    else if (Platform.OS === 'ios' && Keyboard.isVisible()) { waitingForSearchKeyboard.current = true; Keyboard.dismiss(); }
    else clearSearchHandoff();
  }, [chatKeyboardFrozen, clearSearchHandoff, nativePanelAvailable, restorePanelAfterSearch]);
  const prepareNativeStickerSearch = async () => {
    if (nativePanelBusy.current || nativePanelUnknown.current || nativePanelMode.current !== 'panel') return false;
    onStickerSearchVisibilityChange(true);
    const state = { observed: !inputRef.current?.isFocused() };
    searchBlur.current = state;
    const generation = panelGeneration.current;
    const result = await nativePanelAction.current('dismiss');
    if (generation !== panelGeneration.current || searchBlur.current !== state) return false;
    if (result.status !== 'requested') { searchBlur.current = null; clearSearchHandoff(); return false; }
    nativePanelMode.current = 'closed';
    if (!state.observed && inputAreaModule && client) {
      setPanelBusy(true);
      const hostTag = inputAreaHostTag.current, inputTag = findNodeHandle(inputRef.current);
      const scrollTag = messagesRef.current?.getScrollableNode(), generation = panelGeneration.current;
      const scope = client.controller.scope();
      const current = () => active.current === client && scope() && generation === panelGeneration.current && searchBlur.current === state;
      if (hostTag && inputTag && typeof scrollTag === 'number') {
        const observed = await inputAreaModule.probeInputAreaTargets({ hostTag, inputTag, scrollTag, current });
        if (observed.status === 'observed' && !observed.inputFocused) state.observed = true;
      }
      if (searchBlur.current === state) setPanelBusy(false);
    }
    if (searchBlur.current !== state) return false;
    searchBlur.current = null; setPanelBusy(nativePanelBusy.current);
    if (!state.observed) { clearSearchHandoff(); setEmojiOpen(false); setError('搜索暂时无法打开，请重试。'); return false; }
    return true;
  };
  useEffect(() => {
    const hide = Keyboard.addListener('keyboardDidHide', () => {
      if (waitingForSearchKeyboard.current) { waitingForSearchKeyboard.current = false; if (nativePanelAvailable && emojiOpen) restorePanelAfterSearch(); else clearSearchHandoff(); }
      else if (nativePanelAvailable && nativePanelMode.current === 'panel' && !nativePanelBusy.current && !stickerSearchActiveRef.current) {
        // A system dismissal can leave the custom inputView assigned. Reopening
        // must request it again, even when its content is already mounted.
        setEmojiOpen(false);
      }
    });
    const show = Keyboard.addListener('keyboardDidShow', event => {
      if (stickerSearchActiveRef.current) return;
      const height = Math.round(event.endCoordinates.height);
      if (height > 0 && (!nativePanelAvailable || nativePanelMode.current !== 'panel')) setEmojiPanelHeight(height);
      if (nativePanelAvailable) return;
      if (waitingForComposerKeyboard.current) { waitingForComposerKeyboard.current = false; switchingKeyboard.current = false; chatContentInset.value = toolbarHeightRef.current + 20; chatKeyboardFrozen.value = false; setEmojiOpen(false); }
    });
    return () => { hide.remove(); show.remove(); };
  }, [chatContentInset, chatKeyboardFrozen, clearSearchHandoff, nativePanelAvailable, emojiOpen, restorePanelAfterSearch]);
  const ChatKeyboardScroll = useMemo(() => React.forwardRef<React.ComponentRef<typeof ScrollView>, ScrollViewProps>((props, ref) =>
    <KeyboardChatScrollView {...props} ref={ref} automaticallyAdjustContentInsets={false} contentInsetAdjustmentBehavior="never"
      keyboardLiftBehavior="whenAtEnd" freeze={chatKeyboardFrozen} extraContentPadding={chatContentInset} onEndVisible={visible => setShowScrollToBottom(!visible)} />
  ), [chatContentInset, chatKeyboardFrozen]);
  const ComposerContainer = iosChatKeyboard && !nativePanelAvailable ? KeyboardStickyView : View;
  const historyAnchor = useRef<ReturnType<typeof captureHistoryAnchor>>(null);
  const [attachments, setAttachments] = useState<AttachmentDraft[]>([]);
  const attachmentsRef = useRef<AttachmentDraft[]>([]);
  const composerGeneration = useRef(0);
  const [uncertain, setUncertain] = useState<{ outcome: SendOutcome; text: string; ids: string[] } | null>(null);
  const sending = useRef<object | null>(null);
  const preparingCamera = useRef<object | null>(null);
  const [preparingPhoto, setPreparingPhoto] = useState(false);
  const [busy, setBusy] = useState(false);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [error, setError] = useState('');
  const [connecting, setConnecting] = useState(false);
  const [origin, setOrigin] = useState('');
  const [pairing, setPairing] = useState('');
  const [authState, setAuthState] = useState<'setup' | 'signed_out' | 'signed_in' | null>(null);
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [appearance, setAppearance] = useState<AppearanceView | null>(null);
  const [appearanceRevision, setAppearanceRevision] = useState(0);
  const auth = useMemo(() => createNativeAuth(), []);
  const webAuth = useMemo(() => Platform.OS === 'web' ? new WebAuth() : null, []);
  const active = useRef<Client | null>(client);
  const recent = useMemo(() => client && snapshot ? recentStickers(client.controller) : null, [client, snapshot]);
  const draftRef = useRef('');
  const page = dark ? '#15191e' : '#eef0f2';
  const ink = dark ? '#f5f6f7' : '#252832';
  const muted = dark ? '#aaaeb8' : '#747984';
  const composerInset = useAnimatedStyle(() => ({
    paddingBottom: 9 + (emojiOpen ? 0 : Math.max(0, insets.bottom + keyboard.height.value)),
  }), [emojiOpen, insets.bottom]);

  useEffect(() => {
    active.current = client;
    setSnapshot(null);
    if (!client) return;
    const unsubscribe = client.controller.subscribe(setSnapshot);
    void client.controller.start().catch(() => setError('连接失败，请稍后重试。'));
    return () => { unsubscribe(); client.controller.stop(); };
  }, [client]);
  const sessionId = snapshot?.view?.sessionId;
  const inputAreaGeneration = useRef(0);
  const inputAreaSession = useMemo(() => ++inputAreaGeneration.current, [client, sessionId, inputAreaReset]);
  panelGeneration.current = inputAreaSession;
  const inputAreaHostTag = useRef<number | null>(null);
  const hostTagGeneration = useRef(0);
  const inputAreaProbeSequence = useRef(0);
  useEffect(() => {
    // Reset UI immediately for the new scope, but keep a dispatched native
    // request locked until it actually settles.
    nativePanelMode.current = 'closed'; nativePanelUnknown.current = false; pendingPanelOpen.current = null;
    searchHandoffEpoch.current++; searchBlur.current = null; waitingForSearchKeyboard.current = false; restoringPanelAfterSearch.current = false;
    stickerSearchActiveRef.current = false; switchingKeyboard.current = false; waitingForComposerKeyboard.current = false;
    chatKeyboardFrozen.value = false; setStickerSearchActive(false); setEmojiOpen(false); setPanelBusy(nativePanelBusy.current);
    return () => {
      if (hostTagGeneration.current === inputAreaSession) inputAreaHostTag.current = null;
      if (panelTagGeneration.current === inputAreaSession) panelTag.current = null;
      inputAreaProbeSequence.current++; panelRequestSequence.current++; pendingPanelOpen.current = null;
      searchBlur.current = null;
    };
  }, [inputAreaSession, chatKeyboardFrozen]);
  const inspectInputArea = (phase: 'focus' | 'blur') => {
    if (!__DEV__ || Platform.OS !== 'ios' || process.env.EXPO_PUBLIC_ETOS_KEYBOARD_DIAG !== '1' || !client || !inputAreaModule) return;
    const hostTag = inputAreaHostTag.current;
    const scrollTag = messagesRef.current?.getScrollableNode();
    const inputTag = findNodeHandle(inputRef.current);
    if (!hostTag || typeof scrollTag !== 'number' || !inputTag) {
      console.log('[ETOS-KEYBOARD-DIAG]', JSON.stringify({ event: 'inputAreaProbe', phase, status: 'tags_unavailable' }));
      return;
    }
    const current = client.controller.scope(), sequence = ++inputAreaProbeSequence.current;
    void inputAreaModule.probeInputAreaTargets({ hostTag, scrollTag, inputTag, current: () => current() && sequence === inputAreaProbeSequence.current })
      .then(result => { if (current() && sequence === inputAreaProbeSequence.current) console.log('[ETOS-KEYBOARD-DIAG]', JSON.stringify({ event: 'inputAreaProbe', phase, ...result })); });
  };
  nativePanelAction.current = async mode => {
    if (nativePanelBusy.current || nativePanelUnknown.current) return { status: 'unavailable' };
    if (!nativePanelAvailable || !inputAreaModule || !client || !sessionId) { setError('面板暂时无法打开，请稍后再试。'); return { status: 'targets_unavailable' }; }
    const hostTag = inputAreaHostTag.current, currentPanelTag = panelTag.current, inputTag = findNodeHandle(inputRef.current);
    if (!hostTag || !currentPanelTag || !inputTag) { setError('面板暂时无法打开，请稍后再试。'); return { status: 'targets_unavailable' }; }
    nativePanelBusy.current = true; setPanelBusy(true);
    const generation = panelGeneration.current, sequence = ++panelRequestSequence.current, scope = client.controller.scope();
    const current = () => active.current === client && scope() && generation === panelGeneration.current && sequence === panelRequestSequence.current;
    const base = { hostTag, panelTag: currentPanelTag, inputTag, generation, current };
    try {
      const result = await (mode === 'dismiss' ? inputAreaModule.dismissKeyboardPanel(base)
        : inputAreaModule.requestKeyboardPanel({ ...base, mode, height: emojiPanelHeight }));
      if (!current()) {
        if (generation === panelGeneration.current && active.current === client) {
          nativePanelUnknown.current = true; setError('面板状态暂时无法确认，请重启应用后重试。');
        }
        return { status: 'session_changed' };
      }
      if (result.status === 'unavailable' || result.status === 'invalid_response') {
        nativePanelUnknown.current = true;
        setError('面板状态暂时无法确认，请重启应用后重试。');
      } else if (result.status !== 'requested' && result.status !== 'session_changed') setError('面板暂时无法切换，请稍后再试。');
      return result;
    } finally { nativePanelBusy.current = false; setPanelBusy(!!searchBlur.current || restoringPanelAfterSearch.current); }
  };
  useEffect(() => {
    if (!client || !sessionId) return;
    let active = true;
    const current = client.controller.scope();
    const urls: string[] = [];
    const stillCurrent = () => active && current();
    setAppearance(null);
    void (async () => {
      const value = await loadAppearance(client.media, stillCurrent);
      if (!value || !stillCurrent()) return;
      const [avatar, portrait, landscape] = await Promise.all([
        value.companionAvatar ? loadAppearanceImage(client.media, 'companionAvatar', stillCurrent).catch(() => null) : null,
        value.backgrounds ? loadAppearanceImage(client.media, 'portrait', stillCurrent).catch(() => null) : null,
        value.backgrounds ? loadAppearanceImage(client.media, 'landscape', stillCurrent).catch(() => null) : null,
      ]);
      if (!stillCurrent()) return;
      setAppearance({ client, sessionId, name: value.companionName,
        avatar: avatar ? imageUri(avatar, urls) : undefined,
        portrait: portrait ? imageUri(portrait, urls) : undefined,
        landscape: landscape ? imageUri(landscape, urls) : undefined });
    })().catch(() => {});
    return () => { active = false; for (const url of urls) URL.revokeObjectURL(url); };
  }, [client, sessionId, appearanceRevision]);
  useEffect(() => {
    let current = true;
    void (async () => {
      if (Platform.OS === 'web') {
        if (!webAuth) return;
        const seed = developmentSeedAvailable();
        const state = await (seed ? developmentSeedStatus() : webAuth.status());
        if (!current) return;
        setAuthState(state);
        if (state === 'signed_in') {
          setMode(seed ? 'seed' : 'web');
          setClient(seed ? createDevelopmentSeedChat() : createWebChat());
        }
      } else {
        const value = await AsyncStorage.getItem('etos.expo.lastOrigin');
        if (!value || !current) return;
        setOrigin(value);
        auth.select(value);
        await auth.token();
        if (current) { setMode('native'); setClient(createNativeChat(value, auth)); }
      }
    })().catch(() => {
      if (current && Platform.OS === 'web') setError('无法连接，请检查服务地址。');
    }).finally(() => { if (current) setRestoring(false); });
    return () => { current = false; };
  }, [auth, webAuth]);

  const setText = (value: string) => { draftRef.current = value; setDraft(value); };
  const setDrafts = (items: AttachmentDraft[]) => { attachmentsRef.current = items; setAttachments(items); };
  useEffect(() => {
    composerGeneration.current++;
    sending.current = null; preparingCamera.current = null; setPreparingPhoto(false); setBusy(false); setAttachments([]); setUncertain(null); setShowScrollToBottom(false);
    return () => { historyAnchor.current?.cancel(); historyAnchor.current = null; preparingCamera.current = null; composerGeneration.current++; for (const item of attachmentsRef.current) item.release(); attachmentsRef.current = []; };
  }, [client, sessionId]);
  const clearSent = (text: string, ids: string[]) => {
    if (draftRef.current === text) setText('');
    const removed = new Set(ids);
    const keep = attachmentsRef.current.filter(item => !removed.has(item.id));
    attachmentsRef.current.filter(item => removed.has(item.id)).forEach(item => item.release());
    setDrafts(keep);
  };
  useEffect(() => {
    if (!client || !uncertain || snapshot?.view?.sessionId !== uncertain.outcome.sessionId) return;
    let valid = true;
    void client.controller.operationStatus(uncertain.outcome).then(status => {
      if (!valid || active.current !== client) return;
      if (status === 'submitted' || status === 'observed') { clearSent(uncertain.text, uncertain.ids); setUncertain(null); }
      else if (status === 'failed') { setUncertain(null); setError('发送失败，内容仍在输入框中。'); }
    });
    return () => { valid = false; };
  }, [client, snapshot, uncertain]);
  const selectAttachments = async (kind: 'image' | 'file' | 'camera') => {
    if (!client || !snapshot?.view || busy || uncertain || sending.current || preparingCamera.current) return;
    const scope = client.controller.scope(), generation = composerGeneration.current;
    const token = kind === 'camera' ? {} : null;
    if (token) { preparingCamera.current = token; setBusy(true); setError(''); }
    const current = () => active.current === client && composerGeneration.current === generation && scope() && (!token || preparingCamera.current === token);
    let owned: AttachmentDraft[] = [];
    try {
      const selected = await (kind === 'camera' ? capturePhoto(current) : kind === 'image' ? pickImages(current) : pickFiles(current));
      if (!selected) return;
      owned = selected;
      if (!current()) return;
      if (kind === 'camera') {
        const view = client.controller.snapshot().view;
        if (!view) throw new Error('camera_session_unavailable');
        const photo = owned[0]; owned = []; // prepareCameraPhoto takes ownership even on failure.
        setPreparingPhoto(true);
        try { owned = [await prepareCameraPhoto(view, attachmentsRef.current, photo, current)]; }
        catch (error) {
          if (current()) {
            if (error instanceof CameraPhotoError) setError(cameraPhotoMessage(error));
            else setError(attachmentValidationMessage(view, [...attachmentsRef.current, photo], error));
          }
          return;
        }
      }
      if (!current()) return;
      const view = client.controller.snapshot().view;
      if (!view) throw new Error('camera_session_unavailable');
      const next = [...attachmentsRef.current, ...owned];
      try { validateDrafts(view, next); } catch (error) { setError(attachmentValidationMessage(view, next, error)); return; }
      setDrafts(next); owned = []; setError('');
    } catch (error) {
      if (!current()) return;
      if (error instanceof CameraPermissionError) setError(error.canAskAgain ? '需要相机权限才能拍照。' : '相机权限已关闭，请在系统设置中开启。');
      else setError(kind === 'camera' ? '无法打开相机，请重试。' : '无法选择附件，请重试。');
    } finally {
      owned.forEach(item => item.release());
      if (token && preparingCamera.current === token) { preparingCamera.current = null; setPreparingPhoto(false); setBusy(false); }
    }
  };
  const send = async () => {
    const text = draftRef.current, selected = [...attachmentsRef.current];
    if (!client || (!text.trim() && !selected.length) || sending.current || preparingCamera.current || uncertain || snapshot?.connection !== 'online') return;
    const current = client.controller.scope();
    const sendToken = {}; sending.current = sendToken; setBusy(true); setError('');
    try {
      const outcome = await sendDrafts(client.controller, client.media, text, selected);
      if (active.current !== client || !current()) return;
      requestAnimationFrame(() => messagesRef.current?.scrollToEnd({ animated: true }));
      if (outcome.state === 'submitted' || outcome.state === 'observed') clearSent(text, selected.map(item => item.id));
      else if (outcome.state === 'failed') setError('发送失败，内容仍在输入框中。');
      else setUncertain({ outcome, text, ids: selected.map(item => item.id) });
    } catch {
      if (active.current === client && current()) setError('没有发送成功，内容仍在输入框中。');
    } finally { if (sending.current === sendToken) { sending.current = null; setBusy(false); } }
  };
  const chooseSticker = async (sticker: StickerIdentity) => {
    if (!client || busy || sending.current || preparingCamera.current || uncertain || snapshot?.connection !== 'online') return;
    const current = client.controller.scope(), sendToken = {}; sending.current = sendToken; setBusy(true); setError('');
    try {
      const outcome = await sendSticker(client.controller, client.media, sticker);
      if (active.current !== client || !current()) return;
      requestAnimationFrame(() => messagesRef.current?.scrollToEnd({ animated: true }));
      if (outcome.state === 'failed') setError('表情发送失败，请重试。');
      else if (outcome.state === 'unknown') setUncertain({ outcome, text: '', ids: [] });
    } catch { if (active.current === client && current()) setError('表情发送失败，请重试。'); }
    finally { if (sending.current === sendToken) { sending.current = null; setBusy(false); } }
  };
  const connect = async () => {
    if (connecting) return;
    setConnecting(true); setError('');
    try {
      if (Platform.OS === 'web') {
        if (!webAuth) throw new Error('unavailable');
        if (developmentSeedAvailable()) {
          if (await developmentSeedStatus() !== 'signed_in') throw new Error('unavailable');
          setMode('seed'); setClient(createDevelopmentSeedChat()); return;
        }
        if (authState === 'setup') {
          if (!pairing.trim()) { setError('请输入配对码。'); return; }
          await webAuth.pair(pairing.trim()); setPairing('');
        } else await webAuth.signIn();
        setMode('web'); setClient(createWebChat());
      } else {
        auth.select(origin);
        await auth.signIn();
        await AsyncStorage.setItem('etos.expo.lastOrigin', origin.trim());
        setMode('native'); setClient(createNativeChat(origin, auth));
      }
    } catch (e) {
      const code = (e as { code?: string }).code;
      setError(code === 'cancelled' ? '已取消登录。' : code === 'invalid_origin' ? '请输入完整的 HTTPS 服务地址。' : '登录未完成，请检查地址和网络后重试。');
    } finally { setConnecting(false); }
  };
  const openLogin = () => { setSpaceOpen(false); client?.controller.stop(); setClient(null); setMode(null); setError(''); setText(''); };
  const loadOlder = async () => {
    if (historyLoading) return;
    historyAnchor.current?.cancel();
    const anchor = captureHistoryAnchor(messagesRef.current?.getScrollableNode());
    historyAnchor.current = anchor;
    setHistoryLoading(true);
    try { await client?.controller.loadOlder(); anchor?.restore(); }
    catch { anchor?.cancel(); setError('加载更早消息失败。'); }
    finally { setHistoryLoading(false); }
  };
  const signOut = async () => {
    try {
      client?.controller.stop();
      if (mode === 'native') { await auth.signOut(); await AsyncStorage.removeItem('etos.expo.lastOrigin'); }
      if (mode === 'web') await webAuth?.signOut();
      setConfirmSignOut(false); setSpaceOpen(false); setClient(null); setMode(null); setAuthState('signed_out'); setText('');
    } catch { setClient(null); setMode(null); setError('退出未完成，请重新登录后检查连接。'); setConfirmSignOut(false); }
  };
  const workspaceImages = snapshot?.view?.capabilities.workspaceImages === true;
  const messages = useMemo(() => snapshot ? rowsFor(snapshot) : [], [snapshot]);
  const renderMessage = useCallback(({ item, index }: { item: Row; index: number }) => client && sessionId ? <MessageBubble key={item._id} row={item} media={client.media} controller={client.controller} sessionId={sessionId} workspaceImages={workspaceImages} latestRef={index === messages.length - 1 ? latestRef : undefined} /> : null, [client, sessionId, workspaceImages, messages.length]);
  const currentAppearance = appearance?.client === client && appearance.sessionId === sessionId ? appearance : null;
  const title = currentAppearance?.name || snapshot?.view?.name || '聊天';
  const background = width > height ? currentAppearance?.landscape : currentAppearance?.portrait;

  // Navigation must remain available even if a native panel request never
  // settles. Retire its host instead of issuing another native request.
  const navigateFromChat = (navigate: () => void) => {
    if (!nativePanelAvailable) {
      closeEmojiPanel(() => { Keyboard.dismiss(); navigate(); });
      return;
    }
    if (emojiOpenRef.current || nativePanelMode.current === 'panel' || nativePanelBusy.current || nativePanelUnknown.current ||
        pendingPanelOpen.current || searchBlur.current || restoringPanelAfterSearch.current || stickerSearchActiveRef.current) {
      panelGeneration.current = ++inputAreaGeneration.current;
      panelRequestSequence.current++;
      pendingPanelOpen.current = null;
      searchBlur.current = null;
      nativePanelMode.current = 'closed';
      clearSearchHandoff();
      setEmojiOpen(false);
      setInputAreaReset(value => value + 1);
    }
    Keyboard.dismiss();
    navigate();
  };

  if (!client) return <View style={[styles.screen, styles.loginOuter, { backgroundColor: page, paddingTop: insets.top, paddingBottom: insets.bottom }]}>
    <Surface style={styles.loginCard}>
      <Text style={[styles.brand, { color: muted }]}>ETOS</Text>
      <Text style={[styles.loginTitle, { color: ink }]}>回到对话</Text>
      <Text style={[styles.loginDescription, { color: muted }]}>{restoring ? '正在恢复连接…' : '连接你的 CFL，继续与你的伙伴聊天。'}</Text>
      {Platform.OS !== 'web' && <View><Text style={[styles.warning, { color: ink }]}>CFL 服务地址</Text><Input accessibilityLabel="CFL 服务地址" placeholder="https://example.com" autoCapitalize="none" autoCorrect={false} keyboardType="url" value={origin} onChangeText={setOrigin} /></View>}
      {Platform.OS === 'web' && authState === 'setup' && <>
        <Text style={[styles.warning, { color: ink }]}>创建新通行密钥会替换现有密钥，并撤销已有会话和授权。</Text>
        <View><Text style={[styles.warning, { color: ink }]}>配对码</Text><Input accessibilityLabel="配对码" value={pairing} onChangeText={setPairing} autoCapitalize="none" /></View>
      </>}
      {!!error && <Text accessibilityRole="alert" style={styles.errorText}>{error}</Text>}
      <Button variant="prominent" disabled={connecting || restoring} onPress={() => void connect()}>{connecting ? '正在连接…' : authState === 'setup' ? '创建通行密钥' : '登录'}</Button>
    </Surface>
  </View>;

  const spaceHeader = <View style={[styles.topbar, styles.spaceTopbar, { paddingTop: insets.top + 12 }]}>
    <Button size="navigation" accessibilityLabel="返回聊天" icon={{ ios: 'chevron.left', web: 'arrow_back', android: 'arrow_back' }} onPress={() => { setConfirmSignOut(false); setSpaceOpen(false); }} />
    <Button size="sm" variant="soft" onPress={mode === 'seed' ? openLogin : () => setConfirmSignOut(true)} accessibilityLabel={mode === 'seed' ? '切换连接' : '退出登录'}>{mode === 'seed' ? '连接' : '退出'}</Button>
    {confirmSignOut && <Surface style={styles.confirm}><Text style={{ color: ink }}>{mode === 'web' ? '退出会结束当前浏览器会话，也可能撤销关联的原生设备授权。' : '退出此设备的登录？'}</Text><View style={styles.confirmActions}><Button size="sm" onPress={() => setConfirmSignOut(false)}>取消</Button><Button size="sm" variant="prominent" onPress={() => void signOut()}>退出登录</Button></View></Surface>}
  </View>;
  const draftItems = attachments.length > 0 && <ScrollView horizontal showsHorizontalScrollIndicator={false} keyboardShouldPersistTaps="always" style={styles.drafts} contentContainerStyle={styles.draftItems}>{attachments.map(item => {
    const remove = () => { item.release(); setDrafts(attachmentsRef.current.filter(entry => entry.id !== item.id)); };
    return item.kind === 'image' ? <View key={item.id} style={styles.draftImageFrame}>
      <Image testID="draft-image" source={{ uri: item.uri }} style={styles.draftImage} accessibilityLabel={item.name} />
      <View style={styles.draftImageRemove}><Button accessibilityLabel={`移除附件 ${item.name}`} size="overlay" icon={{ ios: 'xmark', web: 'close', android: 'close' }} disabled={busy || !!uncertain} onPress={remove} /></View>
    </View> : <View key={item.id} style={[styles.draftItem, { backgroundColor: dark ? '#343a43' : '#e8ebef' }]}>
      <SymbolView name={{ ios: 'doc', android: 'description', web: 'description' }} size={20} tintColor={ink} /><View><Text numberOfLines={1} ellipsizeMode="middle" style={[styles.draftName, { color: ink }]}>{item.name}</Text>
        <Text style={[styles.draftFileSize, { color: muted }]}>{item.size < 1_000_000 ? `${(item.size / 1000).toFixed(1)} KB` : `${(item.size / 1_000_000).toFixed(1)} MB`}</Text></View>
      <Button accessibilityLabel={`移除附件 ${item.name}`} variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} disabled={busy || !!uncertain} onPress={remove} />
    </View>;
  })}</ScrollView>;
  return <View style={[styles.screen, { backgroundColor: page }]}>
    <View style={[styles.screen, { display: spaceOpen ? 'none' : 'flex' }]}>
      {background && <><Image testID="chat-background" source={{ uri: background }} accessibilityIgnoresInvertColors accessible={false} resizeMode="cover" style={StyleSheet.absoluteFill} /><View pointerEvents="none" style={[StyleSheet.absoluteFill, { backgroundColor: dark ? 'rgba(15,19,24,0.38)' : 'rgba(245,247,250,0.20)' }]} /></>}
      <View style={[styles.shell, { maxWidth: width > 760 ? 760 : undefined }]}>
        <View testID="chat-topbar" pointerEvents="box-none" style={[styles.chatTopbar, { top: insets.top }]}><Surface style={styles.identity}>
          <View testID="chat-avatar" style={styles.avatar}>{currentAppearance?.avatar ? <Image testID="companion-avatar" source={{ uri: currentAppearance.avatar }} accessible={false} style={styles.avatarImage} /> : <Text style={styles.avatarText}>{title.slice(0, 1).toUpperCase()}</Text>}</View>
          <View style={[styles.identityDivider, { backgroundColor: muted }]} />
          <Button accessibilityLabel="打开伴侣空间" variant="ghost" icon={{ ios: 'ellipsis', web: 'more_horiz', android: 'more_horiz' }} onPress={() => navigateFromChat(() => setSpaceOpen(true))} />
        </Surface><Surface style={styles.headerActions}>
          <Button accessibilityLabel="上下文" variant="ghost" icon={{ ios: 'chart.bar', web: 'monitoring', android: 'monitoring' }} onPress={() => navigateFromChat(() => setContextOpen(true))} />
          <Button accessibilityLabel="搜索聊天记录" variant="ghost" icon={{ ios: 'magnifyingglass', web: 'search', android: 'search' }} onPress={() => navigateFromChat(() => setSearchOpen(true))} />
          <Button accessibilityLabel="设置" variant="ghost" icon={{ ios: 'gearshape', web: 'settings', android: 'settings' }} onPress={() => navigateFromChat(() => setSettingsOpen(true))} />
        </Surface></View>
        <View pointerEvents="box-none" style={[styles.chatAlerts, { top: insets.top + 70 }]}>
          {snapshot?.failure === 'access_denied' && <View style={styles.banner}><Text style={styles.errorText}>登录已失效，请重新连接。</Text><Button size="sm" onPress={openLogin}>重新登录</Button></View>}
          {snapshot?.failure === 'unavailable' && <Text style={[styles.bannerText, { color: muted }]}>连接已断开，正在重连…</Text>}
          {!!error && <View style={styles.chatError}><Text accessibilityRole="alert" style={styles.chatErrorText}>{error}</Text></View>}
        </View>
        <View style={styles.chatBody}>
          <KeyboardAvoidingView enabled={!iosChatKeyboard} style={styles.screen} behavior="translate-with-padding">
            <View style={styles.screen}
              onTouchStart={event => {
                if (iosChatKeyboard && emojiOpen && !stickerSearchActive && event.nativeEvent.touches.length === 1) {
                  timelineTouch.current = { x: event.nativeEvent.pageX, y: event.nativeEvent.pageY, started: performance.now() };
                }
              }}
              onTouchMove={event => {
                const start = timelineTouch.current;
                if (start && (Math.abs(event.nativeEvent.pageX - start.x) > 10 || Math.abs(event.nativeEvent.pageY - start.y) > 10)) timelineTouch.current = null;
              }}
              onTouchCancel={() => { timelineTouch.current = null; }}
              onTouchEnd={() => {
                const start = timelineTouch.current;
                timelineTouch.current = null;
                if (start && emojiOpen && !stickerSearchActive && performance.now() - start.started < 350) closeEmojiPanel();
              }}>
            <TimelineViewport>
              <FlashList<Row> key={sessionId ?? 'loading'} ref={messagesRef} data={messages} renderItem={renderMessage} keyExtractor={item => item._id}
                maxItemsInRecyclePool={0} maintainVisibleContentPosition={{ startRenderingFromBottom: true, autoscrollToBottomThreshold: 0.15 }}
                renderScrollComponent={iosChatKeyboard ? ChatKeyboardScroll : undefined}
                contentContainerStyle={{ paddingTop: insets.top + 78, paddingBottom: iosChatKeyboard ? 0 : toolbarHeight + 20 }}
                keyboardDismissMode="interactive" keyboardShouldPersistTaps="handled" onScrollBeginDrag={() => closeEmojiPanel(() => Keyboard.dismiss())}
                onScroll={event => { const { contentOffset, contentSize, layoutMeasurement, contentInset } = event.nativeEvent; keyboardDiagnostic.record('scroll', { offset: Math.round(contentOffset.y), size: Math.round(contentSize.height), viewport: Math.round(layoutMeasurement.height), inset: Math.round(contentInset?.bottom ?? 0) }); if (!iosChatKeyboard) setShowScrollToBottom(contentSize.height - contentOffset.y - layoutMeasurement.height > 120); }} scrollEventThrottle={16}
                ListHeaderComponent={snapshot?.before ? <View style={styles.history}><Button disabled={historyLoading} onPress={() => void loadOlder()}>{historyLoading ? '正在加载…' : '加载更早消息'}</Button></View> : null}
                ListEmptyComponent={<Text style={[styles.empty, { color: muted }]}>从一句问候开始吧</Text>} />
            </TimelineViewport>
            </View>
            {showScrollToBottom && <View style={[styles.scrollToBottom, { bottom: toolbarHeight + 6 }]}><Button accessibilityLabel="回到底部" variant="soft" icon={{ ios: 'arrow.down', web: 'arrow_downward', android: 'arrow_downward' }} onPress={() => messagesRef.current?.scrollToEnd({ animated: true })} /></View>}
            <ComposerContainer {...(iosChatKeyboard && !nativePanelAvailable ? { enabled: !stickerSearchActive } : {})} style={styles.floatingComposer}>
              <Animated.View style={nativePanelAvailable ? nativeStickyStyle : undefined}>
              <View ref={composerRef} testID="floating-composer" onLayout={event => { const height = event.nativeEvent.layout.height; toolbarHeightRef.current = height; keyboardDiagnostic.record('layout', { height: Math.round(height) }); setToolbarHeight(height); }}>
              <StickerPanel key={inputAreaSession} media={client.media} controller={client.controller} sessionId={sessionId ?? ''} recent={recent} disabled={busy || !!uncertain || panelBusy} onSelect={item => void chooseSticker(item)} onClose={() => closeEmojiPanel()} onSearchVisibilityChange={onStickerSearchVisibilityChange} prepareSearch={nativePanelAvailable ? prepareNativeStickerSearch : undefined} dark={dark} enabled={emojiOpen && panelKind === 'stickers'}>{(stickerPanel, stickerSearchSheet) => {
                const panelContent = <View key={`${panelKind}:${panelVersion}`} onLayout={() => { if (panelGeneration.current === inputAreaSession && panelRevision.current === panelVersion) { laidOutPanel.current = { kind: panelKind, generation: inputAreaSession, revision: panelVersion }; presentPendingPanel.current(); } }} style={[styles.bottomPanel, { height: iosChatKeyboard ? emojiPanelHeight : 300, paddingBottom: insets.bottom, backgroundColor: dark ? '#25282d' : '#f7f8fa' }]}>{panelKind === 'stickers' ? <View testID="stickers-panel" style={[styles.screen, { backgroundColor: dark ? '#25282d' : '#f7f8fa' }]}>{stickerPanel}</View> : <AttachmentPanel dark={dark} onClose={() => closeEmojiPanel()} onSelect={kind => closeEmojiPanel(() => void selectAttachments(kind))} />}</View>;
                const inputPanel = nativePanelAvailable && inputAreaModule ? <inputAreaModule.KeyboardPanel scopeGeneration={inputAreaSession} style={styles.nativePanelPlaceholder} onLayout={event => { if (panelGeneration.current === inputAreaSession) { panelTagGeneration.current = inputAreaSession; panelTag.current = findNodeHandle(event.currentTarget) ?? null; presentPendingPanel.current(); } }} accessibilityElementsHidden={!emojiOpen} importantForAccessibility={emojiOpen ? 'auto' : 'no-hide-descendants'}><View collapsable={false} style={{ height: emojiPanelHeight }}>{panelContent}</View></inputAreaModule.KeyboardPanel> : <EmojiPanel open={emojiOpen} panelHeight={emojiPanelHeight} visibleHeight={emojiVisibleHeight} progress={emojiProgress} instantOpen={emojiInstantOpen}>{panelContent}</EmojiPanel>;
                return <>
              <InputArea generation={inputAreaSession} onLayout={event => { if (nativePanelAvailable || (__DEV__ && Platform.OS === 'ios' && process.env.EXPO_PUBLIC_ETOS_KEYBOARD_DIAG === '1')) { if (panelGeneration.current === inputAreaSession) { hostTagGeneration.current = inputAreaSession; inputAreaHostTag.current = findNodeHandle(event.currentTarget) ?? null; presentPendingPanel.current(); } } }} composer={<Animated.View style={[styles.composerOuter, composerInset]} onLayout={event => { chatComposerHeight.value = event.nativeEvent.layout.height; }}>
                <View testID="composer-content">
                  {draftItems}
                  {preparingPhoto && <View accessibilityRole="progressbar" accessibilityLabel="正在处理照片" style={[styles.photoPreparing, { backgroundColor: dark ? '#30343a' : '#f4f5f7' }]}><ActivityIndicator size="small" /><Text style={{ color: ink }}>正在处理照片…</Text></View>}
                  <View style={styles.composerContents}>
                    <Button accessibilityLabel="附件" size="navigation" variant="ghost" icon={{ ios: 'plus', web: 'add', android: 'add' }} disabled={busy || !!uncertain || panelBusy} onPress={() => emojiOpen && panelKind === 'attachments' ? closeEmojiPanel() : openComposerPanel('attachments')} />
                    <Surface style={styles.composerSurface}>
                      <View style={styles.composerField}>
                        <View style={styles.composerInputWrap}>
                        <Text pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
                          onLayout={event => setInputHeight(Math.max(44, Math.min(132, Math.ceil(event.nativeEvent.layout.height))))}
                          style={[styles.composerInputMeasure, styles.composerInput]}>{draft ? `${draft}${draft.endsWith('\n') ? '\u200b' : ''}` : ' '}</Text>
                        <TextInput ref={inputRef} accessibilityLabel="输入消息…" placeholder="输入消息…" placeholderTextColor={muted} value={draft} onChangeText={setText}
                          onPressIn={() => { if (nativePanelAvailable && nativePanelMode.current === 'panel') openSystemKeyboard(); }}
                          onFocus={() => { inspectInputArea('focus'); if (nativePanelAvailable) { if (restoringPanelAfterSearch.current) clearSearchHandoff(); if (!nativePanelBusy.current && nativePanelMode.current !== 'panel') { pendingPanelOpen.current = null; nativePanelMode.current = 'keyboard'; setEmojiOpen(false); } } else if (iosChatKeyboard && emojiOpen) { switchingKeyboard.current = true; chatKeyboardFrozen.value = false; waitingForComposerKeyboard.current = true; } else setEmojiOpen(false); }} onBlur={() => { inspectInputArea('blur'); const pending = searchBlur.current; if (pending) { pending.observed = true; } else if (nativePanelAvailable && nativePanelMode.current === 'panel' && !nativePanelBusy.current && !stickerSearchActiveRef.current) setEmojiOpen(false); }} editable={!busy && !uncertain} multiline maxLength={16000}
                          style={[styles.composerInput, { height: inputHeight, color: ink }]} />
                        </View>
                        <View style={styles.composerEmoji}>
                          <Button disabled={panelBusy} accessibilityLabel={emojiOpen && panelKind === 'stickers' ? '键盘' : '表情'} size="circle" variant="ghost"
                            icon={emojiOpen && panelKind === 'stickers' ? { ios: 'keyboard', web: 'keyboard', android: 'keyboard' } : { ios: 'face.smiling', web: 'sentiment_satisfied', android: 'sentiment_satisfied' }}
                            onPress={() => { keyboardDiagnostic.start(); keyboardDiagnostic.record('emoji'); if (emojiOpen && panelKind === 'stickers') { if (nativePanelAvailable) openSystemKeyboard(); else if (iosChatKeyboard && inputRef.current) { switchingKeyboard.current = true; chatKeyboardFrozen.value = false; waitingForComposerKeyboard.current = true; inputRef.current.focus(); } else { closeEmojiPanel(); requestAnimationFrame(() => inputRef.current?.focus()); } } else openComposerPanel('stickers'); }} />
                        </View>
                      </View>
                    </Surface>
                    <Button accessibilityLabel="发送消息" size="navigation" variant="ghost" icon={{ ios: 'arrow.up', web: 'arrow_upward', android: 'arrow_upward' }} disabled={busy || !!uncertain || snapshot?.connection !== 'online' || (!draft.trim() && attachments.length === 0)} onPress={() => void send()} />
                  </View>
                </View>
              </Animated.View>} panel={inputPanel} />
              {stickerSearchSheet}</>;
              }}</StickerPanel>
              </View>
              </Animated.View>
            </ComposerContainer>
          </KeyboardAvoidingView>
        </View>
        {searchOpen && sessionId && <ChatSearch key={sessionId} controller={client.controller} dark={dark} onClose={() => setSearchOpen(false)} />}
        {settingsOpen && sessionId && <ChatSettings key={sessionId} controller={client.controller} media={client.media} dark={dark} onClose={() => setSettingsOpen(false)} onBackgroundSaved={() => setAppearanceRevision(value => value + 1)} />}
        <BottomSheet isPresented={contextOpen} onDismiss={() => setContextOpen(false)} snapPoints={['half']} containerColor={dark ? '#25282d' : '#f7f8fa'} testID="context-sheet"><RNHostView><View style={styles.contextSheet}>
          <View style={styles.contextHeading}><Text style={[styles.contextTitle, { color: ink }]}>上下文</Text><Button accessibilityLabel="关闭上下文" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={() => setContextOpen(false)} /></View>
          <Text style={{ color: ink }}>{snapshot?.view?.contextUsage.tokens == null ? '暂无上下文用量数据' : `已使用 ${snapshot.view.contextUsage.tokens.toLocaleString()}${snapshot.view.contextUsage.capacity == null ? '' : ` / ${snapshot.view.contextUsage.capacity.toLocaleString()}`} tokens`}</Text>
        </View></RNHostView></BottomSheet>
      </View>
    </View>
    {spaceOpen && <View style={styles.screen}><NativeTabsFrame header={spaceHeader} ink={ink} page={page} dark={dark} bottomInset={insets.bottom} /></View>}
  </View>;
}

export default function App() {
  return <GestureHandlerRootView style={styles.screen}><SafeAreaProvider><KeyboardProvider><AppearanceProvider><AppContent /></AppearanceProvider></KeyboardProvider></SafeAreaProvider></GestureHandlerRootView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1 }, shell: { flex: 1, width: '100%', alignSelf: 'center' },
  topbar: { paddingHorizontal: 18, paddingVertical: 10, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  spaceTopbar: { paddingHorizontal: 20 },
  chatTopbar: { position: 'absolute', left: 0, right: 0, zIndex: 2, paddingHorizontal: 18, paddingVertical: 10, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  headerActions: { borderRadius: 999, flexDirection: 'row', alignItems: 'center', padding: 5 },
  contextSheet: { flex: 1, paddingHorizontal: 16, gap: 12 }, contextHeading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, contextTitle: { fontSize: 19, fontWeight: '600' },
  chatAlerts: { position: 'absolute', left: 0, right: 0, zIndex: 2 },
  chatError: { marginHorizontal: 18, paddingHorizontal: 14, paddingVertical: 10, borderRadius: 14, backgroundColor: '#fff' },
  chatErrorText: { color: '#9c302b', fontSize: 14, lineHeight: 20 },
  identity: { borderRadius: 999, flexDirection: 'row', alignItems: 'center', padding: 5, gap: 5 },
  avatar: { width: 38, height: 38, borderRadius: 19, overflow: 'hidden', backgroundColor: '#a7b9c8', alignItems: 'center', justifyContent: 'center' }, avatarImage: { width: 38, height: 38 },
  avatarText: { color: '#fff', fontSize: 17, fontWeight: '700' }, identityDivider: { width: StyleSheet.hairlineWidth, height: 23, opacity: 0.45 },
  chatBody: { flex: 1, minHeight: 0 }, floatingComposer: { position: 'absolute', bottom: 0, left: 0, right: 0 },
  messageRow: { marginVertical: 4, marginHorizontal: 18, gap: 6 }, mine: { alignSelf: 'flex-end', alignItems: 'flex-end', maxWidth: '78%' }, theirs: { flex: 1, alignItems: 'flex-start' },
  bubble: { borderRadius: 22, paddingHorizontal: 15, paddingVertical: 11 }, myBubble: { borderBottomRightRadius: 7 }, messageText: { fontSize: 16, lineHeight: 23 }, errorSmall: { color: '#ffe2df', fontSize: 11, marginTop: 4 },
  image: { width: 200, height: 150, borderRadius: 16 }, stickerImage: { width: 120, height: 120 }, imageLoading: { width: 140, height: 90, alignItems: 'center', justifyContent: 'center', gap: 6, backgroundColor: '#e1e4e8', borderRadius: 16 }, mediaNotice: { fontSize: 12, color: '#727782' }, contentPlaceholder: { color: '#777f8b', backgroundColor: 'rgba(130,140,150,0.14)', borderRadius: 13, padding: 12, overflow: 'hidden', maxWidth: 240 },
  composerOuter: { paddingTop: 4, paddingHorizontal: 7 }, composerSurface: { flex: 1, borderRadius: 22 },
  composerContents: { flexDirection: 'row', alignItems: 'flex-end', minHeight: 44, gap: 6 },
  composerField: { flexDirection: 'row', alignItems: 'flex-end', minHeight: 44, paddingLeft: 8 },
  composerEmoji: { alignSelf: 'center' },
  composerInputWrap: { flex: 1, minWidth: 0 },
  composerInputMeasure: { position: 'absolute', left: 0, right: 0, top: 0, opacity: 0 },
  composerInput: { fontSize: 16, lineHeight: 22, paddingHorizontal: 4, paddingVertical: 10, textAlignVertical: 'center' },
  bottomPanel: { borderTopLeftRadius: 18, borderTopRightRadius: 18, overflow: 'hidden' },
  nativePanelPlaceholder: { height: 0, width: '100%' },
  attachmentPanel: { flex: 1, paddingHorizontal: 16, paddingTop: 8 },
  attachmentHeading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  attachmentTitle: { fontSize: 17, fontWeight: '600' },
  attachmentActions: { flexDirection: 'row', paddingTop: 20, paddingHorizontal: 4, gap: 20 },
  attachmentAction: { width: 72, alignItems: 'center', gap: 8 },
  attachmentActionLabel: { fontSize: 13 },
  history: { alignItems: 'center', paddingVertical: 10 }, scrollToBottom: { position: 'absolute', right: 12 },
  drafts: { height: 80, flexGrow: 0 }, draftItems: { gap: 8, paddingHorizontal: 8, alignItems: 'center' }, draftItem: { flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 12, padding: 6, maxWidth: 230 }, draftImageFrame: { width: 72, height: 72 }, draftImage: { width: 72, height: 72, borderRadius: 10 }, draftImageRemove: { position: 'absolute', right: -6, top: -6 }, draftName: { maxWidth: 120, fontSize: 13 }, draftFileSize: { fontSize: 11 }, photoPreparing: { alignSelf: 'flex-start', flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 14, paddingVertical: 8, borderRadius: 14, marginLeft: 7 },
  empty: { textAlign: 'center', marginTop: 80 },
  loginOuter: { alignItems: 'center', justifyContent: 'center', paddingHorizontal: 22 }, loginCard: { width: '100%', maxWidth: 390, borderRadius: 28, padding: 26, gap: 16 }, brand: { fontSize: 12, fontWeight: '700', letterSpacing: 3 }, loginTitle: { fontSize: 28, fontWeight: '700' }, loginDescription: { fontSize: 15, lineHeight: 23, marginBottom: 8 }, warning: { fontSize: 13, lineHeight: 20 }, errorText: { color: '#c0524a', fontSize: 13, lineHeight: 19 }, banner: { marginHorizontal: 18, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, bannerText: { textAlign: 'center', fontSize: 12 },
  confirm: { marginHorizontal: 18, padding: 16, borderRadius: 18, gap: 12 }, confirmActions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 8 },
});
