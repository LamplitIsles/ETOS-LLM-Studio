import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';
import { BottomSheet, RNHostView } from '@expo/ui';
import type { SearchCard, SearchReadResult } from '../../vendor/contracts/src/index';
import type { ChatController } from '../cfl/chat';
import { Button } from './Button';
import { Input } from './Input';

export function ChatSearch({ controller, dark, onClose }: { controller: ChatController; dark: boolean; onClose: () => void }) {
  const [query, setQuery] = useState('');
  const [hits, setHits] = useState<SearchCard[]>([]);
  const [searched, setSearched] = useState(false);
  const [limited, setLimited] = useState(false);
  const [selected, setSelected] = useState<SearchReadResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const generation = useRef(0);
  const ink = dark ? '#f4f4f6' : '#252631';
  const muted = dark ? '#b6bcc6' : '#616975';
  useEffect(() => () => { generation.current++; controller.cancelSearch(); }, [controller]);
  const changeQuery = (value: string) => {
    generation.current++; controller.cancelSearch(); setQuery(value); setHits([]); setSelected(null); setSearched(false); setLoading(false); setError('');
  };
  const search = async () => {
    if (!query.trim()) return;
    const id = ++generation.current; setLoading(true); setError(''); setSelected(null); setSearched(true); setHits([]);
    try { const result = await controller.search(query); if (generation.current === id) { setHits(result.hits); setLimited(result.limited); } }
    catch { if (generation.current === id) setError('搜索失败，请检查连接后重试。'); }
    finally { if (generation.current === id) setLoading(false); }
  };
  const open = async (hit: SearchCard) => {
    const id = ++generation.current; setLoading(true); setError(''); setSelected(null);
    try { const result = await controller.searchRead(hit.id); if (generation.current === id) setSelected(result); }
    catch { if (generation.current === id) setError('无法打开这条记录，请重试。'); }
    finally { if (generation.current === id) setLoading(false); }
  };
  const target = selected?.context.targetSourceRecordIndex;
  const targetPresent = selected?.context.items.some(item => item.sourceRecordIndex === target);
  return <BottomSheet isPresented onDismiss={onClose} snapPoints={['full']} containerColor={dark ? '#25282d' : '#f7f8fa'} testID="chat-search-sheet">
    <RNHostView><View style={styles.page}>
      <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>聊天记录搜索</Text><Button accessibilityLabel="关闭聊天搜索" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
      {!selected && <View style={styles.search}><Input style={styles.input} accessibilityLabel="搜索聊天记录" placeholder="搜索聊天记录" value={query} onChangeText={changeQuery} maxLength={500} shape="pill" /><Button disabled={!query.trim() || loading} onPress={() => void search()}>搜索</Button></View>}
      {selected && <Button variant="ghost" onPress={() => { generation.current++; controller.cancelSearch(); setSelected(null); setError(''); }}>返回搜索结果</Button>}
      {loading && <ActivityIndicator />}
      {!!error && <Text accessibilityRole="alert" style={{ color: dark ? '#ffb5ac' : '#9c302b' }}>{error}</Text>}
      <ScrollView keyboardShouldPersistTaps="always" style={styles.results}>
        {selected ? <>
          {!targetPresent && <View style={styles.record}><Text style={{ color: muted }}>{selected.record.role === 'user' ? '你' : '伙伴'}</Text><Text selectable style={{ color: ink }}>{selected.record.content}</Text></View>}
          {selected.context.items.map(item => <View key={item.sourceRecordIndex} style={[styles.record, item.sourceRecordIndex === target && { backgroundColor: dark ? '#444e5b' : '#dbe7f3' }]}>
            <Text style={{ color: muted }}>{item.kind === 'compaction' ? '摘要' : item.role === 'user' ? '你' : '伙伴'}</Text><Text selectable style={{ color: ink }}>{item.content}</Text>
          </View>)}
          {selected.context.truncated && <Text style={{ color: muted }}>部分上下文未显示</Text>}
        </> : <>
          {!loading && searched && !error && hits.length === 0 && <Text style={{ color: muted }}>没有找到聊天记录</Text>}
          {hits.map(hit => <View key={hit.id} style={styles.hit}><Button variant="ghost" onPress={() => void open(hit)}>{hit.snippet.segments.map(segment => segment.text).join('') || '打开记录'}</Button>{hit.sessionName && <Text style={{ color: muted }}>{hit.sessionName}</Text>}</View>)}
          {limited && <Text style={{ color: muted }}>仅显示部分结果，请尝试更具体的搜索词。</Text>}
        </>}
      </ScrollView>
    </View></RNHostView>
  </BottomSheet>;
}
const styles = StyleSheet.create({ page: { flex: 1, gap: 12, paddingHorizontal: 16, paddingBottom: 16 }, heading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, title: { fontSize: 19, fontWeight: '600' }, search: { flexDirection: 'row', alignItems: 'center', gap: 8 }, input: { flex: 1 }, results: { flex: 1 }, hit: { marginVertical: 4, alignItems: 'flex-start' }, record: { padding: 12, marginVertical: 4, borderRadius: 12, gap: 4 } });
