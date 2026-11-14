import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { RNHostView } from '@expo/ui';
import { SymbolView } from 'expo-symbols';
import type { SearchCard, SearchReadResult } from '../../vendor/contracts/src/index';
import type { ChatController } from '../cfl/chat';
import type { ApiTransport } from '../cfl/transport';
import { findArchiveWorkspaceImages } from '../cfl/archive-workspace-images';
import { Button } from './Button';
import { Input } from './Input';
import { MessageText } from './MessageText';
import { MessageSurface } from './MessageSurface';
import { FullSheet } from './FullSheet';

function SearchMessage({ kind, role, text, active, truncated, dark, media, controller, workspaceImages }: {
  kind: 'message' | 'compaction'; role?: 'user' | 'assistant'; text: string; active: boolean; truncated?: boolean;
  dark: boolean; media: ApiTransport; controller: ChatController; workspaceImages: boolean;
}) {
  const mine = kind === 'message' && role === 'user';
  const unknown = kind === 'compaction' || !role;
  const ink = mine ? '#ffffff' : dark ? '#f4f4f6' : '#252631';
  const muted = mine ? '#e1e9f3' : dark ? '#b6bcc6' : '#616975';
  const markdown = useMemo(() => {
    const images = findArchiveWorkspaceImages(text, { workspaceImages, isCurrent: () => true }).images;
    let rendered = '', offset = 0;
    for (const image of images) {
      rendered += `${text.slice(offset, image.start)}![聊天图片](<${image.requestPath}>)`;
      offset = image.end;
    }
    return rendered + text.slice(offset);
  }, [text, workspaceImages]);
  return <View testID={kind === 'compaction' ? 'search-context-summary' : mine ? 'search-context-user' : role === 'assistant' ? 'search-context-assistant' : 'search-context-unknown'}
    style={[styles.messageRow, mine ? styles.mine : styles.theirs]}>
    {unknown && <Text style={[styles.recordLabel, { color: muted }]}>{kind === 'compaction' ? '摘要' : '角色未知'}</Text>}
    <MessageSurface mine={mine} style={active ? { borderWidth: 2, borderColor: dark ? '#96bce2' : '#658db5' } : undefined}>
      <MessageText text={markdown} foreground={ink} dark={mine || dark} media={media} controller={controller} workspaceImages={workspaceImages} />
      {!!truncated && <Text style={{ color: muted }}>内容已截断</Text>}
    </MessageSurface>
  </View>;
}

function SearchContext({ selected, dark, media, controller, workspaceImages }: {
  selected: SearchReadResult; dark: boolean; media: ApiTransport; controller: ChatController; workspaceImages: boolean;
}) {
  const scroll = useRef<React.ComponentRef<typeof ScrollView>>(null);
  const content = useRef<React.ComponentRef<typeof View>>(null);
  const targetView = useRef<React.ComponentRef<typeof View>>(null);
  const layout = useRef({ viewport: 0, content: 0, targetReady: false, interrupted: false, positioned: '', measurement: 0 });
  const target = selected.context.targetSourceRecordIndex;
  const index = selected.context.items.findIndex(item => item.sourceRecordIndex === target);
  const muted = dark ? '#b6bcc6' : '#616975';
  const positionTarget = () => {
    const state = layout.current;
    if (state.interrupted || !scroll.current || !content.current || !targetView.current || !state.targetReady || state.viewport <= 0 || state.content <= 0) return;
    const measurement = ++state.measurement;
    targetView.current.measureLayout(content.current, (_x, y, _width, height) => {
      if (state.interrupted || measurement !== state.measurement || !scroll.current || state.content < y + height - 1) return;
      const geometry = `${state.viewport}:${state.content}:${y}:${height}`;
      if (geometry === state.positioned) return;
      state.positioned = geometry;
      if (index < 1) scroll.current.scrollTo({ y: 0, animated: false });
      else if (index === selected.context.items.length - 1) scroll.current.scrollToEnd({ animated: false });
      else scroll.current.scrollTo({ y: Math.max(0, y - Math.max(0, (state.viewport - height) / 2)), animated: false });
    }, () => {});
  };
  const targetLayout = () => { layout.current.targetReady = true; positionTarget(); };
  return <ScrollView ref={scroll} testID="search-context-scroll" keyboardShouldPersistTaps="always" style={styles.results}
    onLayout={event => { layout.current.viewport = event.nativeEvent.layout.height; positionTarget(); }}
    onContentSizeChange={(_width, height) => { layout.current.content = height; positionTarget(); }}
    onScrollBeginDrag={() => { layout.current.interrupted = true; }}
    onTouchStart={() => { layout.current.interrupted = true; }}
    {...(Platform.OS === 'web' ? { onWheel: () => { layout.current.interrupted = true; } } : {})}>
    <View ref={content} collapsable={false}>
    {index < 0 && <View ref={targetView} collapsable={false} onLayout={targetLayout}><SearchMessage kind={selected.record.kind} role={selected.record.role} text={selected.record.content} active dark={dark} media={media} controller={controller} workspaceImages={workspaceImages} /></View>}
    {selected.context.items.map(item => <View key={item.sourceRecordIndex} ref={item.sourceRecordIndex === target ? targetView : undefined} collapsable={false} onLayout={item.sourceRecordIndex === target ? targetLayout : undefined}>
      <SearchMessage kind={item.sourceRecordIndex === target ? selected.record.kind : item.kind} role={item.sourceRecordIndex === target ? selected.record.role : item.role}
        text={item.sourceRecordIndex === target ? selected.record.content : item.content} active={item.sourceRecordIndex === target}
        truncated={item.sourceRecordIndex !== target && item.truncated} dark={dark} media={media} controller={controller} workspaceImages={workspaceImages} />
    </View>)}
    {selected.context.truncated && <Text style={{ color: muted }}>部分上下文未显示</Text>}
    </View>
  </ScrollView>;
}

function searchDate(value?: string) {
  if (!value) return '';
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? '' : new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(date);
}

export function ChatSearch({ controller, media, workspaceImages, companionName, dark, onClose }: { controller: ChatController; media: ApiTransport; workspaceImages: boolean; companionName: string; dark: boolean; onClose: () => void }) {
  const [query, setQuery] = useState('');
  const [hits, setHits] = useState<SearchCard[]>([]);
  const [searched, setSearched] = useState(false);
  const [limited, setLimited] = useState(false);
  const [estimatedTotal, setEstimatedTotal] = useState<number | null>(null);
  const [selected, setSelected] = useState<SearchReadResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [presented, setPresented] = useState(true);
  const generation = useRef(0);
  const ink = dark ? '#f4f4f6' : '#252631';
  const muted = dark ? '#b6bcc6' : '#616975';
  useEffect(() => () => { generation.current++; controller.cancelSearch(); }, [controller]);
  const changeQuery = (value: string) => {
    generation.current++; controller.cancelSearch(); setQuery(value); setHits([]); setSelected(null); setSearched(false); setLimited(false); setEstimatedTotal(null); setLoading(false); setError('');
  };
  const search = async (searchQuery = query) => {
    if (!searchQuery.trim() || loading) return;
    const id = ++generation.current; setQuery(searchQuery); setLoading(true); setError(''); setSelected(null); setSearched(true); setHits([]); setLimited(false); setEstimatedTotal(null);
    try { const result = await controller.search(searchQuery); if (generation.current === id) { setHits(result.hits); setLimited(result.limited); setEstimatedTotal(result.estimatedTotalHits); } }
    catch { if (generation.current === id) setError('搜索失败，请检查连接后重试。'); }
    finally { if (generation.current === id) setLoading(false); }
  };
  const open = async (hit: SearchCard) => {
    const id = ++generation.current; setLoading(true); setError(''); setSelected(null);
    try { const result = await controller.searchRead(hit.id); if (generation.current === id) setSelected(result); }
    catch { if (generation.current === id) setError('无法打开这条记录，请重试。'); }
    finally { if (generation.current === id) setLoading(false); }
  };
  const back = () => { generation.current++; controller.cancelSearch(); setSelected(null); setError(''); };
  return <FullSheet open={presented} onRequestClose={() => setPresented(false)} onDismiss={onClose} color={dark ? '#25282d' : '#f7f8fa'} testID="chat-search-sheet">
    <RNHostView><View style={styles.page}>
      <View style={styles.heading}><Button accessibilityLabel={selected ? '返回搜索结果' : '关闭聊天搜索'} size="navigation" icon={selected ? { ios: 'chevron.left', web: 'arrow_back', android: 'arrow_back' } : { ios: 'xmark', web: 'close', android: 'close' }} onPress={selected ? back : () => setPresented(false)} /><Text style={[styles.title, { color: ink }]}>聊天记录</Text></View>
      {!selected && <View style={styles.search}><Input style={styles.input} accessibilityLabel="搜索聊天记录" placeholder="搜索聊天记录" value={query} onChangeText={changeQuery} onSubmitEditing={value => void search(value)} returnKeyType="search" maxLength={500} shape="pill" autoFocus /><Button accessibilityLabel="搜索" size="navigation" icon={{ ios: 'magnifyingglass', web: 'search', android: 'search' }} disabled={!query.trim() || loading} onPress={() => void search()} /></View>}
      {loading && <ActivityIndicator />}
      {!!error && <Text accessibilityRole="alert" style={{ color: dark ? '#ffb5ac' : '#9c302b' }}>{error}</Text>}
      {selected ? <SearchContext key={selected.record.id} selected={selected} dark={dark} media={media} controller={controller} workspaceImages={workspaceImages} /> :
      <ScrollView keyboardShouldPersistTaps="always" style={styles.results}>
          {!loading && searched && !error && hits.length === 0 && <Text style={{ color: muted }}>没有找到聊天记录</Text>}
          {!loading && searched && !error && hits.length > 0 && <Text style={[styles.resultCount, { color: muted }]}>{`找到 ${estimatedTotal ?? hits.length} 条结果${limited || (estimatedTotal !== null && estimatedTotal > hits.length) ? ` · 仅显示前 ${hits.length} 条` : ''}`}</Text>}
          {hits.length > 0 && <View style={[styles.hitList, { backgroundColor: dark ? '#292d32' : '#ffffff' }]}>{hits.map((hit, index) => {
            const snippet = hit.snippet.segments.map(segment => segment.text).join('');
            const sender = hit.kind === 'compaction' ? '记忆摘要' : hit.role === 'user' ? '你' : hit.role === 'assistant' ? companionName : '角色未知';
            const date = searchDate(hit.createdAt);
            return <Pressable key={hit.id} accessibilityRole="button" accessibilityLabel={[sender, date, snippet].filter(Boolean).join('，')} accessibilityHint="打开聊天记录" onPress={() => void open(hit)}
              style={[styles.hitButton, index > 0 && { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: dark ? '#51565d' : '#d9dde2' }]}>
              <View style={styles.hitContent}><Text numberOfLines={1} style={[styles.hitSender, { color: ink }]}>{sender}</Text>
                {!!date && <Text style={[styles.hitDate, { color: ink }]}>{date}</Text>}
                <Text numberOfLines={2} style={[styles.hitSnippet, { color: muted }]}>{hit.snippet.segments.map((segment, part) => <Text key={part} testID={segment.highlighted ? 'search-highlight' : undefined} style={segment.highlighted ? { backgroundColor: dark ? '#b88a2f' : '#ffdf82', color: '#241b09' } : undefined}>{segment.text}</Text>)}</Text>
              </View><SymbolView name={{ ios: 'chevron.right', web: 'chevron_right', android: 'chevron_right' }} size={18} tintColor={muted} />
            </Pressable>;
          })}</View>}
      </ScrollView>}
    </View></RNHostView>
  </FullSheet>;
}
const styles = StyleSheet.create({ page: { flex: 1, gap: 12, paddingHorizontal: 16, paddingBottom: 16 }, heading: { flexDirection: 'row', alignItems: 'center', gap: 8 }, title: { fontSize: 19, fontWeight: '600' }, search: { flexDirection: 'row', alignItems: 'center', gap: 8 }, input: { flex: 1 }, results: { flex: 1 }, resultCount: { marginTop: 8, marginBottom: 12, fontSize: 14 }, hitList: { borderRadius: 16, overflow: 'hidden' }, hitButton: { minHeight: 72, flexDirection: 'row', alignItems: 'flex-start', gap: 8, paddingHorizontal: 14, paddingVertical: 12 }, hitContent: { flex: 1, gap: 3 }, hitSender: { fontSize: 16, fontWeight: '600' }, hitDate: { fontSize: 13 }, hitSnippet: { fontSize: 14, lineHeight: 20 }, messageRow: { marginVertical: 4, maxWidth: '78%' }, mine: { alignSelf: 'flex-end', alignItems: 'flex-end' }, theirs: { alignSelf: 'flex-start', alignItems: 'flex-start' }, recordLabel: { marginBottom: 4, fontSize: 12 } });
