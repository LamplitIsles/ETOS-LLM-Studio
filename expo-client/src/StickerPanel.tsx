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
import { recentStickerIdentity, type RecentSticker, type RecentStickers } from './cfl/recent-stickers';
import type { ApiTransport } from './cfl/transport';
import { Input } from './ui/Input';
import { Button } from './ui/Button';
import { ImageButton } from './ui/ImageButton';

type ThumbnailCache = Map<string, string>;
type ContentSnapshot = { stickers: Sticker[]; cursor: string | null; firstPage: string };

function StickerImage({ sticker, catalog, size, cache, current, original = false }: { sticker: Sticker; catalog: StickerClient; size: number; cache: ThumbnailCache; current: () => boolean; original?: boolean }) {
  const [uri, setUri] = useState<string | null>(() => original || !current() ? null : cache.get(sticker.version) ?? null);
  useEffect(() => {
    let alive = true;
    const remembered = original || !current() ? undefined : cache.get(sticker.version);
    setUri(remembered ?? null);
    if (remembered) return () => { alive = false; };
    void catalog.media(sticker.version, original ? 'original' : 'thumbnail').then(image => {
      if (!alive || !current() || !image) return;
      let binary = '';
      for (let i = 0; i < image.bytes.length; i += 8192) binary += String.fromCharCode(...image.bytes.subarray(i, i + 8192));
      const next = `data:${image.contentType};base64,${btoa(binary)}`;
      if (!original && next.length <= 256_000) {
        cache.set(sticker.version, next);
        while (cache.size > 32) cache.delete(cache.keys().next().value!);
      }
      setUri(next);
    }).catch(() => {});
    return () => { alive = false; };
  }, [cache, catalog, current, sticker.version, original]);
  return uri ? <Image source={{ uri }} style={{ width: size, height: size }} resizeMode="contain" accessible={false} /> : <View style={{ width: size, height: size }} />;
}

function StickerCell({ sticker, catalog, cache, current, favorite, favoriteBusy, disabled, size, onSelect, onFavorite, onPreview }: {
  sticker: Sticker; catalog: StickerClient; favorite: boolean | null; favoriteBusy: boolean; disabled: boolean; size: number;
  cache: ThumbnailCache; current: () => boolean;
  onSelect: (sticker: Sticker) => void; onFavorite: (sticker: Sticker) => void; onPreview: (sticker: Sticker | null) => void;
}) {
  const held = useRef(false);
  const reset = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (reset.current) clearTimeout(reset.current); }, []);
  const begin = useCallback(() => { held.current = true; onPreview(sticker); }, [onPreview, sticker]);
  const end = useCallback(() => {
    if (!held.current) return;
    onPreview(null);
    if (reset.current) clearTimeout(reset.current);
    reset.current = setTimeout(() => { held.current = false; }, 300);
  }, [onPreview]);
  const hold = useMemo(() => Gesture.LongPress().minDuration(450).maxDistance(10)
    .onStart(() => { runOnJS(begin)(); }).onFinalize(() => { runOnJS(end)(); }), [begin, end]);
  return <View style={[styles.cell, { width: '20%', height: size + 8 }]}>
    <GestureDetector gesture={hold}><View>
      <ImageButton size={size} label={`发送表情 ${sticker.name}`} disabled={disabled || !sticker.available}
        onPress={() => { if (!held.current) onSelect(sticker); }}>
        <StickerImage sticker={sticker} catalog={catalog} cache={cache} current={current} size={size - 8} />
      </ImageButton>
    </View></GestureDetector>
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

export function StickerPanel({ media, controller, sessionId, recent, onSelect, disabled, dark, onClose, onSearchVisibilityChange, prepareSearch, enabled, children }: {
  media: ApiTransport; controller: ChatController; sessionId: string; recent: RecentStickers | null; onSelect: (sticker: StickerIdentity) => void;
  disabled: boolean; dark: boolean; onClose: () => void; onSearchVisibilityChange?: (visible: boolean) => void;
  prepareSearch?: () => Promise<boolean>;
  enabled: boolean; children: (panel: React.ReactNode, searchSheet: React.ReactNode) => React.ReactNode;
}) {
  const [catalog, setCatalog] = useState<StickerClient | null>(null);
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
  const [preview, setPreview] = useState<Sticker | null>(null);
  const alive = useRef(false), requestId = useRef(0), searchRequestId = useRef(0), favoriteId = useRef(0), packId = useRef(0), busyRef = useRef(false);
  const selectedRef = useRef(selection); selectedRef.current = selection;
  const current = useMemo(() => controller.scope(), [controller, sessionId]);
  const thumbnails = useMemo<ThumbnailCache>(() => new Map(), [catalog]);
  const snapshots = useMemo(() => new Map<string, ContentSnapshot>(), [catalog]);
  const { width } = useWindowDimensions();
  const cellSize = Math.max(42, Math.min(68, Math.floor((Math.min(width, 760) - 40) / 5)));
  const ink = dark ? '#f4f4f6' : '#252631';

  useEffect(() => {
    if (!enabled || !sessionId) return;
    const current = controller.scope(), abort = new AbortController(); alive.current = true;
    setCatalog(new StickerClient(media, sessionId, () => alive.current && current(), abort.signal));
    return () => { alive.current = false; requestId.current++; searchRequestId.current++; favoriteId.current++; packId.current++; abort.abort(); };
  }, [controller, media, sessionId, enabled]);
  useEffect(() => { const timer = setTimeout(() => setSearch(query.trim()), 250); return () => clearTimeout(timer); }, [query]);
  const loadPacks = useCallback(async (next: string | null) => {
    if (!catalog) return;
    const token = ++packId.current; setPacksLoading(true); setPackError(false);
    try {
      const page = await catalog.page('packs', { cursor: next });
      if (!alive.current || token !== packId.current || !('packs' in page)) return;
      setPacks(old => next ? [...old, ...page.packs.filter(pack => !old.some(item => item.id === pack.id))] : page.packs);
      setPackCursor(page.nextCursor);
    } catch { if (alive.current && token === packId.current) setPackError(true); }
    finally { if (alive.current && token === packId.current) setPacksLoading(false); }
  }, [catalog]);
  const loadFavorites = useCallback(async () => {
    if (!catalog) return null;
    const token = ++favoriteId.current, ids = new Set<string>(), seen = new Set<string>();
    let next: string | null = null;
    do {
      const page = await catalog.page('favorites', { cursor: next });
      if (!alive.current || token !== favoriteId.current || !('stickers' in page)) return null;
      page.stickers.forEach(sticker => ids.add(sticker.id)); next = page.nextCursor;
      if (next && seen.has(next)) throw new Error('repeated_cursor');
      if (next) seen.add(next);
    } while (next);
    if (alive.current && token === favoriteId.current) setFavoriteIds(ids);
    return ids;
  }, [catalog]);
  const load = useCallback(async (next: string | null) => {
    if (!catalog) return;
    const previous = snapshots.get(selection);
    const request = ++requestId.current; setLoading(!!next || !previous); setFailed(false);
    try {
      const page = await catalog.page(selection === 'favorites' ? 'favorites' : 'pack', {
        cursor: next, ...(selection === 'favorites' ? {} : { packId: selection }),
      });
      if (!alive.current || request !== requestId.current || !('stickers' in page)) return;
      const firstPage = JSON.stringify([page.stickers, page.nextCursor]);
      const items = next ? [...(previous?.stickers ?? []), ...page.stickers.filter(sticker => !previous?.stickers.some(item => item.id === sticker.id))]
        : previous?.firstPage === firstPage ? previous.stickers : page.stickers;
      const nextCursor = !next && previous?.firstPage === firstPage ? previous.cursor : page.nextCursor;
      snapshots.delete(selection);
      snapshots.set(selection, { stickers: items, cursor: nextCursor, firstPage: next ? previous?.firstPage ?? firstPage : firstPage });
      if (snapshots.size > 12) snapshots.delete(snapshots.keys().next().value!);
      setStickers(items); setCursor(nextCursor);
    } catch { if (alive.current && request === requestId.current) setFailed(true); }
    finally { if (alive.current && request === requestId.current) setLoading(false); }
  }, [catalog, selection, snapshots]);
  const loadSearch = useCallback(async (next: string | null) => {
    if (!catalog || !searchOpen || !search || search !== query.trim()) return;
    const request = ++searchRequestId.current; setSearchLoading(true); setSearchFailed(false);
    try {
      const page = await catalog.page('search', { cursor: next, query: search });
      if (!alive.current || request !== searchRequestId.current || !('stickers' in page)) return;
      setSearchResults(old => next ? [...old, ...page.stickers.filter(sticker => !old.some(item => item.id === sticker.id))] : page.stickers);
      setSearchCursor(page.nextCursor);
    } catch { if (alive.current && request === searchRequestId.current) setSearchFailed(true); }
    finally { if (alive.current && request === searchRequestId.current) setSearchLoading(false); }
  }, [catalog, query, search, searchOpen]);
  useEffect(() => { if (catalog) { void loadPacks(null); void loadFavorites().catch(() => { if (alive.current) setFavoriteMessage('收藏加载失败，请重试。'); }); } }, [catalog, loadPacks, loadFavorites]);
  useEffect(() => {
    const remembered = snapshots.get(selection);
    setStickers(remembered?.stickers ?? []); setCursor(remembered?.cursor ?? null); setPreview(null);
    if (catalog) void load(null);
    return () => { requestId.current++; };
  }, [catalog, load, retry, selection, snapshots]);
  useEffect(() => {
    setSearchResults([]); setSearchCursor(null); setSearchFailed(false); setSearchLoading(false);
    if (searchOpen && search && search === query.trim() && catalog) void loadSearch(null);
    return () => { searchRequestId.current++; };
  }, [catalog, loadSearch, query, search, searchOpen, searchRetry]);
  const toggleFavorite = useCallback(async (sticker: Sticker) => {
    if (!catalog || favoriteIds === null || busyRef.current) return;
    const desired = !favoriteIds.has(sticker.id); busyRef.current = true; setFavoriteBusy(true); setFavoriteMessage(''); favoriteId.current++;
    snapshots.delete('favorites');
    if (selectedRef.current === 'favorites') requestId.current++;
    let failedWrite = false;
    try { await catalog.favorite(sticker.id, desired); } catch { failedWrite = true; }
    try {
      const ids = await loadFavorites();
      if (!alive.current || !ids) return;
      if (failedWrite) setFavoriteMessage('收藏状态已刷新；如有需要，请再次操作。');
    } catch { if (alive.current) { setFavoriteIds(null); setFavoriteMessage('收藏状态暂时无法确认，请重试刷新。'); } }
    finally {
      snapshots.delete('favorites'); busyRef.current = false;
      if (alive.current) { setFavoriteBusy(false); if (selectedRef.current === 'favorites') { requestId.current++; setRetry(value => value + 1); } }
    }
  }, [catalog, favoriteIds, loadFavorites, snapshots]);
  const choose = (id: string) => {
    if (id === selection) return;
    requestId.current++;
    const remembered = snapshots.get(id);
    setStickers(remembered?.stickers ?? []); setCursor(remembered?.cursor ?? null);
    setLoading(false); setFailed(false); setPreview(null); setSelection(id);
  };
  const changeQuery = (value: string) => { searchRequestId.current++; setQuery(value); setSearchResults([]); setSearchCursor(null); setSearchLoading(false); setSearchFailed(false); };
  const searchDismissed = () => { if (searchPresented.current) { searchPresented.current = false; onSearchVisibilityChange?.(false); } };
  const closeSearch = () => { searchRequestId.current++; setPreview(null); setSearchOpen(false); if (Platform.OS !== 'ios') searchDismissed(); setQuery(''); setSearch(''); };
  const panel = <View style={styles.panel}>
    <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>表情</Text><Button accessibilityLabel="关闭表情" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
    <ScrollView horizontal showsHorizontalScrollIndicator={false} keyboardShouldPersistTaps="always" style={styles.tabs} contentContainerStyle={styles.tabItems}>
      <Button accessibilityLabel="搜索表情" disabled={disabled} variant="ghost" icon={{ ios: 'magnifyingglass', web: 'search', android: 'search' }} onPress={() => {
        if (!prepareSearch) { onSearchVisibilityChange?.(true); searchPresented.current = true; setSearchMounted(true); setSearchOpen(true); return; }
        void prepareSearch().then(ready => { if (ready && alive.current) { searchPresented.current = true; setSearchMounted(true); setSearchOpen(true); } });
      }} />
      <Button accessibilityLabel="收藏" variant={selection === 'favorites' ? 'soft' : 'ghost'}
        icon={{ ios: 'heart', web: 'favorite_border', android: 'favorite_border' }} onPress={() => choose('favorites')} />
      {catalog && packs.map(pack => <View key={pack.id} style={[styles.packTab, selection === pack.id && styles.selectedTab]}>
        <ImageButton size={42} label={pack.name} onPress={() => choose(pack.id)}><StickerImage sticker={pack.cover} catalog={catalog} cache={thumbnails} current={current} size={30} /></ImageButton>
      </View>)}
      {(packCursor || packError) && <Button accessibilityLabel="加载更多表情包" variant="ghost" disabled={packsLoading} onPress={() => void loadPacks(packError && !packs.length ? null : packCursor)}>···</Button>}
    </ScrollView>
    {!!favoriteMessage && <Button variant="ghost" onPress={() => { setFavoriteMessage(''); void loadFavorites().catch(() => setFavoriteMessage('收藏加载失败，请重试。')); }}>{favoriteMessage}</Button>}
    {selection === 'favorites' ? null : <Text style={[styles.packName, { color: ink }]}>{packs.find(pack => pack.id === selection)?.name}</Text>}
    <ScrollView keyboardShouldPersistTaps="always" style={styles.scroll}>
      <View style={styles.grid}>{catalog && stickers.map(sticker => <StickerCell key={`${sticker.id}:${sticker.version}`} sticker={sticker} catalog={catalog} cache={thumbnails} current={current}
        favorite={favoriteIds ? favoriteIds.has(sticker.id) : null} favoriteBusy={favoriteBusy} disabled={disabled} size={cellSize}
        onSelect={onSelect} onFavorite={item => void toggleFavorite(item)} onPreview={setPreview} />)}</View>
      {loading && <ActivityIndicator />}
      {!loading && failed && <Button variant="ghost" onPress={() => setRetry(n => n + 1)}>加载失败，点击重试</Button>}
      {!loading && !failed && !stickers.length && <Text style={[styles.empty, { color: ink }]}>暂无表情</Text>}
      {!loading && cursor && <Button variant="ghost" onPress={() => void load(cursor)}>加载更多</Button>}
    </ScrollView>
    {!searchOpen && preview && catalog && <View testID="sticker-preview" pointerEvents="none" style={[styles.preview, { backgroundColor: dark ? '#33383f' : '#f7f8fa' }]}>
      <StickerImage sticker={preview} catalog={catalog} cache={thumbnails} current={current} size={144} original /><Text numberOfLines={1} style={{ color: ink }}>{preview.name}</Text>
    </View>}
  </View>;
  const searchSheet = <StickerSearchSheet open={searchOpen} onRequestClose={closeSearch} onDismiss={searchDismissed} color={dark ? '#25282d' : '#f7f8fa'}>
      {(Platform.OS === 'ios' ? searchMounted : searchOpen) && <RNHostView><View style={styles.searchSheet}>
        <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>搜索表情</Text><Button accessibilityLabel="关闭搜索" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={closeSearch} /></View>
        <Input accessibilityLabel="搜索表情名称或标签" value={query} onChangeText={changeQuery} placeholder="搜索表情名称或标签" autoFocus shape="pill" style={styles.search} />
        {!!favoriteMessage && <Button variant="ghost" onPress={() => { setFavoriteMessage(''); void loadFavorites().catch(() => setFavoriteMessage('收藏加载失败，请重试。')); }}>{favoriteMessage}</Button>}
        <ScrollView keyboardShouldPersistTaps="always" style={styles.scroll}>
          {!query.trim() && recent && recent.items.length > 0 && <><Text style={[styles.packName, { color: ink }]}>最近使用</Text>
            <View style={styles.grid}>{recent.items.map(item => <RecentCell key={item.id} item={item} recent={recent} media={media} controller={controller} size={cellSize} disabled={disabled} onSelect={onSelect} />)}</View></>}
          <View style={styles.grid}>{catalog && searchResults.map(sticker => <StickerCell key={`${sticker.id}:${sticker.version}`} sticker={sticker} catalog={catalog} cache={thumbnails} current={current}
            favorite={favoriteIds ? favoriteIds.has(sticker.id) : null} favoriteBusy={favoriteBusy} disabled={disabled} size={cellSize}
            onSelect={onSelect} onFavorite={item => void toggleFavorite(item)} onPreview={setPreview} />)}</View>
          {(searchLoading || (!!query.trim() && search !== query.trim())) && <ActivityIndicator />}
          {!searchLoading && searchFailed && <Button variant="ghost" onPress={() => setSearchRetry(n => n + 1)}>加载失败，点击重试</Button>}
          {!searchLoading && !searchFailed && !!search && search === query.trim() && !searchResults.length && <Text style={[styles.empty, { color: ink }]}>没有找到表情</Text>}
          {!searchLoading && search === query.trim() && searchCursor && <Button variant="ghost" onPress={() => void loadSearch(searchCursor)}>加载更多</Button>}
        </ScrollView>
        {preview && catalog && <View testID="sticker-preview" pointerEvents="none" style={[styles.preview, { backgroundColor: dark ? '#33383f' : '#f7f8fa' }]}>
          <StickerImage sticker={preview} catalog={catalog} cache={thumbnails} current={current} size={144} original /><Text numberOfLines={1} style={{ color: ink }}>{preview.name}</Text>
        </View>}
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
  preview: { position: 'absolute', alignSelf: 'center', top: 45, width: 180, height: 182, borderRadius: 16, padding: 12, alignItems: 'center', justifyContent: 'center', zIndex: 5 },
});
