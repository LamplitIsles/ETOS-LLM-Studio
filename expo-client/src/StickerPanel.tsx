import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Image, Platform, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { runOnJS } from 'react-native-reanimated';
import { RNHostView } from '@expo/ui';
import { StickerSearchSheet } from './ui/StickerSearchSheet';
import type { Sticker, StickerPack } from '../vendor/contracts/src/stickers';
import type { StickerIdentity } from '../vendor/contracts/src/index';
import type { ChatController } from './cfl/chat';
import { StickerClient } from './cfl/stickers';
import { createStickerCache } from './cfl/sticker-cache';
import type { ImageData } from './cfl/transport';
import { recentStickerIdentity, type RecentSticker, type RecentStickers } from './cfl/recent-stickers';
import type { ApiTransport } from './cfl/transport';
import { Input } from './ui/Input';
import { Button } from './ui/Button';
import { ImageButton } from './ui/ImageButton';
import { Surface } from './ui/Surface';
import { stickerPreviewPosition } from './ui/stickerPreviewPosition';
import { StickerPopover } from './ui/StickerPopover';

type ThumbnailCache = Map<string, string>;
type ContentSnapshot = { stickers: Sticker[]; cursor: string | null; firstPage: string };
type PreviewTarget = { sticker: Sticker; position: ReturnType<typeof stickerPreviewPosition> };
type PreviewAnchor = { host: { x: number; y: number; width: number }; anchor: { x: number; top: number } };
type PreviewHost = React.RefObject<React.ComponentRef<typeof View> | null>;

function StickerImage({ sticker, catalog, size, cache, current, onError, original = false }: { sticker: Sticker; catalog: StickerClient; size: number; cache: ThumbnailCache; current: () => boolean; onError: (error: unknown) => void; original?: boolean }) {
  const [uri, setUri] = useState<string | null>(() => !current() ? null : cache.get(sticker.version) ?? null);
  useEffect(() => {
    let alive = true, networkCompleted = false;
    const remembered = !current() ? undefined : cache.get(sticker.version);
    setUri(remembered ?? null);
    if (remembered && !original) return () => { alive = false; };
    const show = (image: ImageData) => {
      if (!alive || !current()) return;
      let binary = '';
      for (let i = 0; i < image.bytes.length; i += 8192) binary += String.fromCharCode(...image.bytes.subarray(i, i + 8192));
      const next = `data:${image.contentType};base64,${btoa(binary)}`;
      if (!original && next.length <= 256_000) {
        cache.delete(sticker.version); cache.set(sticker.version, next);
        let characters = 0; for (const item of cache.values()) characters += item.length;
        while ((characters > 12 * 1024 * 1024 || cache.size > 128) && cache.size) {
          const key = cache.keys().next().value!; characters -= cache.get(key)!.length; cache.delete(key);
        }
      }
      setUri(next);
    };
    if (!remembered) void catalog.cachedMedia(sticker.version).then(image => {
      if (!networkCompleted && image) show(image);
    }).catch(onError);
    void catalog.media(sticker.version, original ? 'original' : 'thumbnail').then(image => {
      networkCompleted = !!image || !original;
      if (image) show(image);
      else if (!original && alive && current()) { cache.delete(sticker.version); setUri(null); }
    }).catch(onError);
    return () => { alive = false; };
  }, [cache, catalog, current, sticker.version, original, onError]);
  return uri ? <Image source={{ uri }} style={{ width: size, height: size }} resizeMode="contain" accessible={false} /> : <View style={{ width: size, height: size }} />;
}

function StickerPreview({ target, catalog, cache, current, onError, ink, dark }: {
  target: PreviewTarget; catalog: StickerClient; cache: ThumbnailCache; current: () => boolean;
  onError: (error: unknown) => void; ink: string; dark: boolean;
}) {
  const { sticker, position } = target;
  return <View testID="sticker-preview" pointerEvents="none" style={[styles.preview, { left: position.left, top: position.top, width: position.width }]}>
    <Surface style={styles.previewBubble}>
      <StickerImage key={sticker.version} sticker={sticker} catalog={catalog} cache={cache} current={current} onError={onError} size={144} original />
      <Text numberOfLines={2} style={{ color: ink, textAlign: 'center' }}>{sticker.name}</Text>
    </Surface>
    <View style={[styles.previewTail, { left: position.tailX - 9, borderTopColor: dark ? '#33383f' : '#f7f8fa' }]} />
  </View>;
}

function StickerCell({ sticker, catalog, cache, current, onError, favorite, favoriteBusy, disabled, active, ink, size, onSelect, onFavorite, onPreview, hostRef }: {
  sticker: Sticker; catalog: StickerClient; favorite: boolean | null; favoriteBusy: boolean; disabled: boolean; active: boolean; ink: string; size: number;
  cache: ThumbnailCache; current: () => boolean; onError: (error: unknown) => void;
  onSelect: (sticker: Sticker) => void; onFavorite: (sticker: Sticker) => void; onPreview: (sticker: Sticker | null, anchor?: PreviewAnchor) => void; hostRef: PreviewHost;
}) {
  const held = useRef(false), holding = useRef(false), measurement = useRef(0);
  const [popoverShown, setPopoverShown] = useState(false);
  const touchRef = useRef<React.ComponentRef<typeof View>>(null);
  const reset = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { measurement.current++; if (holding.current) onPreview(null); if (reset.current) clearTimeout(reset.current); }, [onPreview]);
  useEffect(() => { if (!active || disabled || !sticker.available) setPopoverShown(false); }, [active, disabled, sticker.available]);
  const begin = useCallback((x: number, y: number, absoluteX: number, absoluteY: number) => {
    held.current = true; holding.current = true;
    if (Platform.OS === 'ios') { setPopoverShown(true); return; }
    const token = ++measurement.current, host = hostRef.current, target = touchRef.current;
    if (!host || !target) return;
    target.measureLayout(host, (left, top) => {
      host.measure((_x, _y, width) => {
        if (!holding.current || token !== measurement.current || width <= 0) return;
        onPreview(sticker, { host: { x: absoluteX - x - left, y: absoluteY - y - top, width }, anchor: { x: absoluteX, top: absoluteY - y } });
      });
    }, () => {});
  }, [hostRef, onPreview, sticker]);
  const end = useCallback(() => {
    if (!held.current) return;
    setPopoverShown(false);
    holding.current = false; measurement.current++; onPreview(null);
    if (reset.current) clearTimeout(reset.current);
    reset.current = setTimeout(() => { held.current = false; }, 300);
  }, [onPreview]);
  const hold = useMemo(() => Gesture.LongPress().minDuration(450).maxDistance(10)
    .enabled(!disabled && sticker.available)
    .onStart(event => { runOnJS(begin)(event.x, event.y, event.absoluteX, event.absoluteY); }).onFinalize(() => { runOnJS(end)(); }), [begin, end, disabled, sticker.available]);
  const select = useCallback(() => { if (!disabled && sticker.available) onSelect(sticker); }, [disabled, onSelect, sticker]);
  const tap = useMemo(() => Gesture.Tap().enabled(!disabled && sticker.available)
    .onEnd((_event, success) => { if (success) runOnJS(select)(); }), [disabled, sticker.available, select]);
  const iosGesture = useMemo(() => Gesture.Exclusive(hold, tap), [hold, tap]);
  const image = <ImageButton size={size} label={`发送表情 ${sticker.name}`} disabled={disabled || !sticker.available}
    onPress={() => { if (!held.current) select(); }}>
    <StickerImage sticker={sticker} catalog={catalog} cache={cache} current={current} onError={onError} size={size - 8} />
  </ImageButton>;
  return <View style={[styles.cell, { width: '20%', height: size + 8 }]}>
    {Platform.OS === 'ios' ? <GestureDetector gesture={iosGesture}><View ref={touchRef} collapsable={false} accessible
      accessibilityRole="button" accessibilityLabel={`发送表情 ${sticker.name}`} accessibilityState={{ disabled: disabled || !sticker.available }}
      onAccessibilityTap={select} style={{ width: size, height: size }}><View pointerEvents="none" accessibilityElementsHidden>
        <StickerPopover shown={popoverShown} onDismiss={() => setPopoverShown(false)} size={size}
          preview={<View style={styles.nativePreview}><StickerImage key={sticker.version} sticker={sticker} catalog={catalog} cache={cache} current={current} onError={onError} size={144} original /><Text numberOfLines={2} style={[styles.nativePreviewName, { color: ink }]}>{sticker.name}</Text></View>}>
          <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}><StickerImage sticker={sticker} catalog={catalog} cache={cache} current={current} onError={onError} size={size - 8} /></View>
        </StickerPopover></View></View></GestureDetector>
      : <GestureDetector gesture={hold}><View ref={touchRef} collapsable={false}>{image}</View></GestureDetector>}
    <View style={styles.favorite}><Button accessibilityLabel={`${favorite ? '取消收藏' : '收藏'} ${sticker.name}`} variant="ghost"
      icon={{ ios: favorite ? 'heart.fill' : 'heart', web: favorite ? 'favorite' : 'favorite_border', android: favorite ? 'favorite' : 'favorite_border' }}
      disabled={favorite === null || favoriteBusy} onPress={() => onFavorite(sticker)} /></View>
  </View>;
}

function RecentCell({ item, recent, media, controller, size, disabled, onSelect }: {
  item: RecentSticker; recent: RecentStickers; media: ApiTransport; controller: ChatController; size: number; disabled: boolean;
  onSelect: (sticker: StickerIdentity) => void;
}) {
  const [uri, setUri] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    const abort = new AbortController();
    setUri(null);
    if (item.image.availability === 'available') void controller.readImage(media, item.image.attachmentId, () => active && recent.current(), 'original', abort.signal).then(image => {
      if (!active || !recent.current()) return;
      let binary = '';
      for (let i = 0; i < image.bytes.length; i += 8192) binary += String.fromCharCode(...image.bytes.subarray(i, i + 8192));
      setUri(`data:${image.contentType};base64,${btoa(binary)}`);
    }).catch(() => {});
    return () => { active = false; abort.abort(); };
  }, [controller, media, item.image.attachmentId, item.image.availability, recent]);
  return <View style={[styles.cell, { width: '20%', height: size + 8 }]}><ImageButton size={size} label={`发送最近表情 ${item.image.name}`} disabled={disabled || !uri}
    onPress={() => { const identity = recentStickerIdentity(controller, recent, item); if (identity) onSelect(identity); }}>
    {uri ? <Image source={{ uri }} style={{ width: size - 8, height: size - 8 }} resizeMode="contain" accessible={false} /> : <View style={{ width: size - 8, height: size - 8 }} />}
  </ImageButton></View>;
}

export function StickerPanel({ media, controller, sessionId, recent, favoritesRevision, externalFavoriteBusy, claimFavorite, releaseFavorite, onSelect, disabled, dark, onClose, onSearchVisibilityChange, prepareSearch, enabled, onLogin, authDenied, children }: {
  media: ApiTransport; controller: ChatController; sessionId: string; recent: RecentStickers | null; favoritesRevision: number; externalFavoriteBusy: boolean; claimFavorite: () => object | null; releaseFavorite: (token: object) => void; onSelect: (sticker: StickerIdentity) => void;
  disabled: boolean; dark: boolean; onClose: () => void; onSearchVisibilityChange?: (visible: boolean) => void;
  prepareSearch?: () => Promise<boolean>;
  enabled: boolean; onLogin: () => void; authDenied: boolean; children: (panel: React.ReactNode, searchSheet: React.ReactNode) => React.ReactNode;
}) {
  const [catalog, setCatalog] = useState<StickerClient | null>(null);
  const [denied, setDenied] = useState(false);
  const deniedRef = useRef(false);
  const [selection, setSelection] = useState('favorites');
  const [searchOpen, setSearchOpen] = useState(false);
  const searchPresented = useRef(false);
  const [searchMounted, setSearchMounted] = useState(false);
  const [query, setQuery] = useState('');
  const [search, setSearch] = useState('');
  const [searchResults, setSearchResults] = useState<Sticker[]>([]);
  const [searchCursor, setSearchCursor] = useState<string | null>(null);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchFailed, setSearchFailed] = useState(false);
  const [searchRetry, setSearchRetry] = useState(0);
  const [packs, setPacks] = useState<StickerPack[]>([]);
  const [packCursor, setPackCursor] = useState<string | null>(null);
  const packsRef = useRef(packs); packsRef.current = packs;
  const [packsLoading, setPacksLoading] = useState(false);
  const [packError, setPackError] = useState(false);
  const [stickers, setStickers] = useState<Sticker[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  const [favoriteIds, setFavoriteIds] = useState<Set<string> | null>(null);
  const [favoriteBusy, setFavoriteBusy] = useState(false);
  const [favoriteMessage, setFavoriteMessage] = useState('');
  const [preview, setPreview] = useState<PreviewTarget | null>(null);
  const panelRef = useRef<React.ComponentRef<typeof View>>(null), searchRef = useRef<React.ComponentRef<typeof View>>(null);
  const alive = useRef(false), requestId = useRef(0), searchRequestId = useRef(0), favoriteId = useRef(0), packId = useRef(0), busyRef = useRef(false);
  const seenFavoritesRevision = useRef(favoritesRevision);
  const invalidFavoriteCache = useRef(false);
  const selectedRef = useRef(selection); selectedRef.current = selection;
  const current = useMemo(() => {
    const scope = controller.scope();
    return () => scope() && !deniedRef.current && controller.snapshot().view?.sessionId === sessionId && controller.snapshot().failure !== 'access_denied';
  }, [controller, sessionId]);
  const thumbnails = useMemo<ThumbnailCache>(() => new Map(), [controller, media, sessionId]);
  const snapshots = useMemo(() => new Map<string, ContentSnapshot>(), [controller, media, sessionId]);
  const disk = useMemo(() => createStickerCache(), []);
  const invalidate = useCallback(() => {
    if (deniedRef.current) return;
    deniedRef.current = true; setDenied(true);
    requestId.current++; searchRequestId.current++; favoriteId.current++; packId.current++;
    thumbnails.clear(); snapshots.clear(); setStickers([]); setPacks([]); setSearchResults([]); setFavoriteIds(null); setPreview(null);
  }, [thumbnails, snapshots]);
  const handleError = useCallback((error: unknown) => {
    if (error instanceof Error && error.message === 'access_denied' && alive.current && controller.snapshot().view?.sessionId === sessionId) invalidate();
  }, [controller, sessionId, invalidate]);
  useEffect(() => { if (authDenied) invalidate(); }, [authDenied, invalidate]);
  const clearPreview = useCallback(() => setPreview(null), []);
  const showPreview = useCallback((sticker: Sticker | null, target?: PreviewAnchor) => {
    if (!sticker || !target) { setPreview(null); return; }
    const { host, anchor } = target;
    if (!current() || !Number.isFinite(host.x + host.y + host.width + anchor.x + anchor.top) || host.width <= 0) return;
    setPreview({ sticker, position: stickerPreviewPosition(host, anchor) });
  }, [current]);
  const { width } = useWindowDimensions();
  const cellSize = Math.max(42, Math.min(68, Math.floor((Math.min(width, 760) - 40) / 5)));
  const ink = dark ? '#f4f4f6' : '#252631';

  useEffect(() => {
    if (!enabled || !sessionId) return;
    const abort = new AbortController(); alive.current = true;
    if (deniedRef.current) return () => { alive.current = false; abort.abort(); };
    setCatalog(new StickerClient(media, sessionId, () => alive.current && current(), abort.signal, disk));
    return () => { alive.current = false; requestId.current++; searchRequestId.current++; favoriteId.current++; packId.current++; abort.abort(); };
  }, [controller, media, sessionId, enabled, current, disk]);
  useEffect(() => { const timer = setTimeout(() => setSearch(query.trim()), 250); return () => clearTimeout(timer); }, [query]);
  const loadPacks = useCallback(async (next: string | null) => {
    if (!catalog) return;
    const token = ++packId.current; setPacksLoading(true); setPackError(false);
    try {
      let networkCompleted = false;
      const options = { cursor: next };
      if (next || !packsRef.current.length) void catalog.cachedPage('packs', options).then(page => {
        if (!networkCompleted && alive.current && current() && token === packId.current && page && 'packs' in page) {
          setPacks(old => next ? [...old, ...page.packs.filter(pack => !old.some(item => item.id === pack.id))] : page.packs);
          setPackCursor(page.nextCursor);
        }
      }).catch(handleError);
      const page = await catalog.page('packs', options); networkCompleted = true;
      if (!alive.current || !current() || token !== packId.current || !('packs' in page)) return;
      setPacks(old => next ? [...old, ...page.packs.filter(pack => !old.some(item => item.id === pack.id))] : page.packs);
      setPackCursor(page.nextCursor);
    } catch (error) { handleError(error); if (alive.current && current() && token === packId.current) setPackError(true); }
    finally { if (alive.current && token === packId.current) setPacksLoading(false); }
  }, [catalog, current, handleError]);
  const loadFavorites = useCallback(async () => {
    if (!catalog) return null;
    const token = ++favoriteId.current, ids = new Set<string>(), seen = new Set<string>();
    let next: string | null = null;
    do {
      const page = await catalog.page('favorites', { cursor: next });
      if (!alive.current || !current() || token !== favoriteId.current || !('stickers' in page)) return null;
      page.stickers.forEach(sticker => ids.add(sticker.id)); next = page.nextCursor;
      if (next && seen.has(next)) throw new Error('repeated_cursor');
      if (next) seen.add(next);
    } while (next);
    if (alive.current && token === favoriteId.current) setFavoriteIds(ids);
    return ids;
  }, [catalog, current]);
  const load = useCallback(async (next: string | null) => {
    if (!catalog) return;
    const previous = snapshots.get(selection);
    const request = ++requestId.current; setLoading(!!next || !previous); setFailed(false);
    try {
      const kind = selection === 'favorites' ? 'favorites' : 'pack';
      const options = { cursor: next, ...(selection === 'favorites' ? {} : { packId: selection }) };
      let networkCompleted = false;
      if ((next || !previous) && !(kind === 'favorites' && invalidFavoriteCache.current)) void catalog.cachedPage(kind, options).then(page => {
        if (networkCompleted || !alive.current || !current() || request !== requestId.current || (kind === 'favorites' && invalidFavoriteCache.current) || !page || !('stickers' in page)) return;
        const firstPage = JSON.stringify([page.stickers, page.nextCursor]);
        const items = next ? [...(previous?.stickers ?? []), ...page.stickers.filter(sticker => !previous?.stickers.some(item => item.id === sticker.id))] : page.stickers;
        snapshots.delete(selection);
        snapshots.set(selection, { stickers: items, cursor: page.nextCursor, firstPage: next ? previous?.firstPage ?? firstPage : firstPage });
        if (snapshots.size > 12) snapshots.delete(snapshots.keys().next().value!);
        setStickers(items); setCursor(page.nextCursor); setLoading(false);
      }).catch(handleError);
      const page = await catalog.page(kind, options); networkCompleted = true;
      if (!alive.current || !current() || request !== requestId.current || !('stickers' in page)) return;
      if (kind === 'favorites' && !next) invalidFavoriteCache.current = false;
      const firstPage = JSON.stringify([page.stickers, page.nextCursor]);
      const items = next ? [...(previous?.stickers ?? []), ...page.stickers.filter(sticker => !previous?.stickers.some(item => item.id === sticker.id))]
        : previous?.firstPage === firstPage ? previous.stickers : page.stickers;
      const nextCursor = !next && previous?.firstPage === firstPage ? previous.cursor : page.nextCursor;
      snapshots.delete(selection);
      snapshots.set(selection, { stickers: items, cursor: nextCursor, firstPage: next ? previous?.firstPage ?? firstPage : firstPage });
      if (snapshots.size > 12) snapshots.delete(snapshots.keys().next().value!);
      setStickers(items); setCursor(nextCursor);
    } catch (error) { handleError(error); if (alive.current && current() && request === requestId.current) setFailed(true); }
    finally { if (alive.current && request === requestId.current) setLoading(false); }
  }, [catalog, selection, snapshots, current, handleError]);
  const loadSearch = useCallback(async (next: string | null) => {
    if (!catalog || !searchOpen || !search || search !== query.trim()) return;
    const request = ++searchRequestId.current; setSearchLoading(true); setSearchFailed(false);
    try {
      const page = await catalog.page('search', { cursor: next, query: search });
      if (!alive.current || !current() || request !== searchRequestId.current || !('stickers' in page)) return;
      setSearchResults(old => next ? [...old, ...page.stickers.filter(sticker => !old.some(item => item.id === sticker.id))] : page.stickers);
      setSearchCursor(page.nextCursor);
    } catch (error) { handleError(error); if (alive.current && current() && request === searchRequestId.current) setSearchFailed(true); }
    finally { if (alive.current && request === searchRequestId.current) setSearchLoading(false); }
  }, [catalog, query, search, searchOpen, current, handleError]);
  useEffect(() => { if (catalog) { void loadPacks(null); void loadFavorites().catch(error => { handleError(error); if (alive.current && current()) setFavoriteMessage('收藏加载失败，请重试。'); }); } }, [catalog, loadPacks, loadFavorites, current, handleError]);
  useEffect(() => {
    if (seenFavoritesRevision.current === favoritesRevision) return;
    seenFavoritesRevision.current = favoritesRevision;
    invalidFavoriteCache.current = true;
    if (!catalog) return;
    snapshots.delete('favorites');
    void loadFavorites().catch(() => { if (alive.current) { setFavoriteIds(null); setFavoriteMessage('收藏状态暂时无法确认，请重试刷新。'); } });
    if (selectedRef.current === 'favorites') { requestId.current++; setRetry(value => value + 1); }
  }, [catalog, favoritesRevision, loadFavorites, snapshots]);
  useEffect(() => {
    const remembered = snapshots.get(selection);
    setStickers(remembered?.stickers ?? []); setCursor(remembered?.cursor ?? null); clearPreview();
    if (catalog) void load(null);
    return () => { requestId.current++; };
  }, [catalog, load, retry, selection, snapshots, clearPreview]);
  useEffect(() => {
    if (!searchOpen) return;
    setSearchResults([]); setSearchCursor(null); setSearchFailed(false); setSearchLoading(false);
    if (search && search === query.trim() && catalog) void loadSearch(null);
    return () => { searchRequestId.current++; };
  }, [catalog, loadSearch, query, search, searchOpen, searchRetry]);
  const toggleFavorite = useCallback(async (sticker: Sticker) => {
    if (!catalog || favoriteIds === null || busyRef.current) return;
    const token = claimFavorite(); if (!token) return;
    const desired = !favoriteIds.has(sticker.id); busyRef.current = true; invalidFavoriteCache.current = true; setFavoriteBusy(true); setFavoriteMessage(''); favoriteId.current++;
    snapshots.delete('favorites');
    if (selectedRef.current === 'favorites') requestId.current++;
    let failedWrite = false;
    try { await catalog.favorite(sticker.id, desired); } catch (error) { handleError(error); failedWrite = true; }
    try {
      const ids = await loadFavorites();
      if (!alive.current || !ids) return;
      if (failedWrite) setFavoriteMessage('收藏状态已刷新；如有需要，请再次操作。');
    } catch (error) { handleError(error); if (alive.current && current()) { setFavoriteIds(null); setFavoriteMessage('收藏状态暂时无法确认，请重试刷新。'); } }
    finally {
      snapshots.delete('favorites'); busyRef.current = false;
      releaseFavorite(token);
      if (alive.current) { setFavoriteBusy(false); if (selectedRef.current === 'favorites') { requestId.current++; setRetry(value => value + 1); } }
    }
  }, [catalog, favoriteIds, loadFavorites, snapshots, claimFavorite, releaseFavorite, handleError, current]);
  const choose = (id: string) => {
    if (id === selection) return;
    requestId.current++;
    const remembered = snapshots.get(id);
    setStickers(remembered?.stickers ?? []); setCursor(remembered?.cursor ?? null);
    setLoading(false); setFailed(false); clearPreview(); setSelection(id);
  };
  const changeQuery = (value: string) => { searchRequestId.current++; setQuery(value); setSearchResults([]); setSearchCursor(null); setSearchLoading(false); setSearchFailed(false); };
  const searchDismissed = () => {
    if (!searchPresented.current) return;
    searchPresented.current = false;
    setQuery(''); setSearch(''); setSearchResults([]); setSearchCursor(null);
    setSearchLoading(false); setSearchFailed(false); clearPreview();
    onSearchVisibilityChange?.(false);
  };
  const closeSearch = () => { searchRequestId.current++; setSearchOpen(false); if (Platform.OS !== 'ios') searchDismissed(); };
  const panel = denied ? <View style={styles.panel}>
    <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>表情</Text><Button accessibilityLabel="关闭表情" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
    <Button variant="ghost" onPress={onLogin}>登录已失效，重新登录</Button>
  </View> : <View ref={panelRef} collapsable={false} style={styles.panel}>
    <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>表情</Text><Button accessibilityLabel="关闭表情" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
    <ScrollView horizontal showsHorizontalScrollIndicator={false} keyboardShouldPersistTaps="always" style={styles.tabs} contentContainerStyle={styles.tabItems}>
      <Button accessibilityLabel="搜索表情" disabled={disabled} variant="ghost" icon={{ ios: 'magnifyingglass', web: 'search', android: 'search' }} onPress={() => {
        if (!prepareSearch) { onSearchVisibilityChange?.(true); searchPresented.current = true; setSearchMounted(true); setSearchOpen(true); return; }
        void prepareSearch().then(ready => { if (ready && alive.current) { searchPresented.current = true; setSearchMounted(true); setSearchOpen(true); } });
      }} />
      <Button accessibilityLabel="收藏" variant={selection === 'favorites' ? 'soft' : 'ghost'}
        icon={{ ios: 'heart', web: 'favorite_border', android: 'favorite_border' }} onPress={() => choose('favorites')} />
      {catalog && packs.map(pack => <View key={pack.id} style={[styles.packTab, selection === pack.id && styles.selectedTab]}>
        <ImageButton size={42} label={pack.name} onPress={() => choose(pack.id)}><StickerImage sticker={pack.cover} catalog={catalog} cache={thumbnails} current={current} onError={handleError} size={30} /></ImageButton>
      </View>)}
      {(packCursor || packError) && <Button accessibilityLabel="加载更多表情包" variant="ghost" disabled={packsLoading} onPress={() => void loadPacks(packError && !packs.length ? null : packCursor)}>···</Button>}
    </ScrollView>
    {!!favoriteMessage && <Button variant="ghost" onPress={() => { setFavoriteMessage(''); void loadFavorites().catch(error => { handleError(error); if (current()) setFavoriteMessage('收藏加载失败，请重试。'); }); }}>{favoriteMessage}</Button>}
    {selection === 'favorites' ? null : <Text style={[styles.packName, { color: ink }]}>{packs.find(pack => pack.id === selection)?.name}</Text>}
    <ScrollView keyboardShouldPersistTaps="always" style={styles.scroll}>
      <View style={styles.grid}>{catalog && stickers.map(sticker => <StickerCell key={`${sticker.id}:${sticker.version}`} sticker={sticker} catalog={catalog} cache={thumbnails} current={current} onError={handleError}
        favorite={favoriteIds ? favoriteIds.has(sticker.id) : null} favoriteBusy={favoriteBusy || externalFavoriteBusy} disabled={disabled} active={enabled && !searchOpen} ink={ink} size={cellSize}
        onSelect={onSelect} onFavorite={item => void toggleFavorite(item)} onPreview={showPreview} hostRef={panelRef} />)}</View>
      {loading && <ActivityIndicator />}
      {!loading && failed && <Button variant="ghost" onPress={() => setRetry(n => n + 1)}>加载失败，点击重试</Button>}
      {!loading && !failed && !stickers.length && <Text style={[styles.empty, { color: ink }]}>暂无表情</Text>}
      {!loading && cursor && <Button variant="ghost" onPress={() => void load(cursor)}>加载更多</Button>}
    </ScrollView>
    {!searchOpen && preview && catalog && <StickerPreview target={preview} catalog={catalog} cache={thumbnails} current={current} onError={handleError} ink={ink} dark={dark} />}
  </View>;
  const searchSheet = <StickerSearchSheet open={searchOpen && !denied} onRequestClose={closeSearch} onDismiss={searchDismissed} color={dark ? '#25282d' : '#f7f8fa'}>
      {(Platform.OS === 'ios' ? searchMounted : searchOpen) && <RNHostView><View ref={searchRef} collapsable={false} style={styles.searchSheet}>
        <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>搜索表情</Text><Button accessibilityLabel="关闭搜索" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={closeSearch} /></View>
        <Input accessibilityLabel="搜索表情名称或标签" value={query} onChangeText={changeQuery} placeholder="搜索表情名称或标签" autoFocus shape="pill" style={styles.search} />
        {!!favoriteMessage && <Button variant="ghost" onPress={() => { setFavoriteMessage(''); void loadFavorites().catch(error => { handleError(error); if (current()) setFavoriteMessage('收藏加载失败，请重试。'); }); }}>{favoriteMessage}</Button>}
        <ScrollView keyboardShouldPersistTaps="always" style={styles.scroll}>
          {!query.trim() && recent && recent.items.length > 0 && <><Text style={[styles.packName, { color: ink }]}>最近使用</Text>
            <View style={styles.grid}>{recent.items.map(item => <RecentCell key={item.id} item={item} recent={recent} media={media} controller={controller} size={cellSize} disabled={disabled} onSelect={onSelect} />)}</View></>}
          <View style={styles.grid}>{catalog && searchResults.map(sticker => <StickerCell key={`${sticker.id}:${sticker.version}`} sticker={sticker} catalog={catalog} cache={thumbnails} current={current} onError={handleError}
            favorite={favoriteIds ? favoriteIds.has(sticker.id) : null} favoriteBusy={favoriteBusy || externalFavoriteBusy} disabled={disabled} active={enabled && searchOpen} ink={ink} size={cellSize}
            onSelect={onSelect} onFavorite={item => void toggleFavorite(item)} onPreview={showPreview} hostRef={searchRef} />)}</View>
          {(searchLoading || (!!query.trim() && search !== query.trim())) && <ActivityIndicator />}
          {!searchLoading && searchFailed && <Button variant="ghost" onPress={() => setSearchRetry(n => n + 1)}>加载失败，点击重试</Button>}
          {!searchLoading && !searchFailed && !!search && search === query.trim() && !searchResults.length && <Text style={[styles.empty, { color: ink }]}>没有找到表情</Text>}
          {!searchLoading && search === query.trim() && searchCursor && <Button variant="ghost" onPress={() => void loadSearch(searchCursor)}>加载更多</Button>}
        </ScrollView>
        {preview && catalog && <StickerPreview target={preview} catalog={catalog} cache={thumbnails} current={current} onError={handleError} ink={ink} dark={dark} />}
      </View></RNHostView>}
    </StickerSearchSheet>;
  return <>{children(panel, searchSheet)}</>;
}
const styles = StyleSheet.create({
  panel: { flex: 1, paddingHorizontal: 12 }, searchSheet: { flex: 1 }, heading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, title: { fontSize: 16, fontWeight: '600' }, search: { marginTop: 8 },
  tabs: { flexGrow: 0 }, tabItems: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingVertical: 6 },
  packTab: { borderRadius: 10 }, selectedTab: { backgroundColor: '#8a919b33' }, packName: { fontSize: 12, opacity: 0.65, paddingVertical: 4 },
  scroll: { flex: 1 }, grid: { flexDirection: 'row', flexWrap: 'wrap', paddingVertical: 8 }, cell: { alignItems: 'center', position: 'relative' },
  favorite: { position: 'absolute', right: -3, top: -4, transform: [{ scale: 0.58 }] }, empty: { textAlign: 'center', padding: 14 },
  preview: { position: 'absolute', zIndex: 5 }, previewBubble: { height: 216, borderRadius: 16, padding: 16, alignItems: 'center', gap: 8 },
  nativePreview: { width: 192, height: 216, padding: 16, alignItems: 'center', gap: 8 }, nativePreviewName: { textAlign: 'center' },
  previewTail: { position: 'absolute', top: 215, width: 0, height: 0, borderLeftWidth: 9, borderRightWidth: 9, borderTopWidth: 9, borderLeftColor: 'transparent', borderRightColor: 'transparent' },
});
