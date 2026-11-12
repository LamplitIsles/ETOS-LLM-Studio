import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import { Host, TextInput, useNativeState } from '@expo/ui';
import { TtsSettingsClient, type TtsKeyProvider, type TtsProvider, type TtsSnapshot, type TtsVoicePage } from '../cfl/tts-settings';
import type { ChatController } from '../cfl/chat';
import type { ApiTransport } from '../cfl/transport';
import { Button } from './Button';
import { Input } from './Input';

const providers: { id: TtsProvider; label: string }[] = [
  { id: 'minimax', label: 'MiniMax' }, { id: 'alibaba', label: '阿里云' },
  { id: 'bytedance', label: '火山引擎' }, { id: 'elevenlabs', label: 'ElevenLabs' },
];

function SecretInput({ value, onChange, dark, disabled }: { value: string; onChange: (value: string) => void; dark: boolean; disabled: boolean }) {
  const native = useNativeState(value), previous = useRef(value);
  useEffect(() => { if (previous.current !== value) { previous.current = value; native.set(value); } }, [native, value]);
  return <Host ignoreSafeArea="keyboard" style={{ width: '100%' }}><TextInput value={native} secureTextEntry autoCapitalize="none" autoCorrect={false} autoComplete="off"
    accessibilityLabel="语音服务密钥" placeholder="输入新的 API 密钥" editable={!disabled} maxLength={512}
    onChangeText={next => { previous.current = next; onChange(next); }} style={{ width: '100%', backgroundColor: dark ? '#30343a' : '#fff', borderRadius: 14 }}
    textStyle={{ fontSize: 16, color: dark ? '#f5f6f7' : '#252832' }} /></Host>;
}

export function VoiceSettings({ controller, media, dark }: { controller: ChatController; media: ApiTransport; dark: boolean }) {
  const clientRef = useRef<TtsSettingsClient | null>(null), alive = useRef(false), busyRef = useRef(false), generation = useRef(0);
  const [snapshot, setSnapshot] = useState<TtsSnapshot | null>(null);
  const [provider, setProvider] = useState<TtsProvider>('elevenlabs');
  const [voice, setVoice] = useState(''), [speed, setSpeed] = useState(''), [apiKey, setApiKey] = useState('');
  const [voices, setVoices] = useState<TtsVoicePage['voices']>([]), [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true), [notice, setNotice] = useState('');
  const ink = dark ? '#f4f4f6' : '#252631', muted = dark ? '#b6bcc6' : '#616975';
  const assign = (value: TtsSnapshot, selected = value.provider ?? 'elevenlabs') => {
    setSnapshot(value); setProvider(selected); setVoice(value.voices[selected]);
    setSpeed(selected === 'minimax' || selected === 'bytedance' ? String(value.speeds[selected] ?? '') : '');
    setApiKey(''); setVoices([]); setCursor(null);
  };
  const getClient = () => {
    let client = clientRef.current;
    if (!client?.current()) { client?.dispose(); client = new TtsSettingsClient(controller, media, () => alive.current); clientRef.current = client; }
    return client;
  };
  const load = async () => {
    if (busyRef.current) return;
    const id = ++generation.current; setLoading(true); setNotice('');
    try { const value = await getClient().load(); if (alive.current && id === generation.current) assign(value); }
    catch { if (alive.current && id === generation.current) { setSnapshot(null); setNotice('无法读取语音设置，请检查连接。'); } }
    finally { if (alive.current && id === generation.current) setLoading(false); }
  };
  useEffect(() => { alive.current = true; void load(); return () => { alive.current = false; generation.current++; clientRef.current?.dispose(); clientRef.current = null; }; }, [controller, media]);
  const changeProvider = (next: TtsProvider) => {
    if (!snapshot || busyRef.current) return;
    generation.current++; assign(snapshot, next); setNotice('');
  };
  const save = async (kind: 'settings' | 'key') => {
    if (busyRef.current || !snapshot) return;
    const value = apiKey; setApiKey('');
    const parsedSpeed = speed.trim() === '' ? null : Number(speed);
    if (kind === 'settings' && (!voice.trim() || (parsedSpeed !== null && (!Number.isFinite(parsedSpeed) || parsedSpeed < 0.5 || parsedSpeed > 2)))) { setNotice('请填写声音 ID；语速应在 0.5 到 2 之间。'); return; }
    if (kind === 'key' && (provider === 'minimax' || !value)) return;
    const id = ++generation.current; busyRef.current = true; setLoading(true); setNotice('');
    try {
      const client = getClient();
      const result = kind === 'key' ? await client.setKey(provider as TtsKeyProvider, value) : await client.save({ provider, voice: voice.trim(), speed: provider === 'minimax' || provider === 'bytedance' ? parsedSpeed : null });
      if (!alive.current || generation.current !== id) return;
      if (result.state === 'saved') {
        if ('snapshot' in result) assign(result.snapshot as TtsSnapshot, provider);
        else if (provider !== 'minimax') setSnapshot(old => old && ({ ...old, configured: { ...old.configured, [provider]: true } }));
        setNotice(kind === 'key' ? '密钥已保存。' : '语音设置已保存。');
      } else if (result.state === 'unknown') { setSnapshot(null); setNotice('提交结果未确认。刷新只显示当前状态，不会自动重发。'); }
      else if (result.state === 'tts_settings_busy') setNotice('语音设置正在更新，请稍后再试。');
      else if (result.state === 'tts_unsupported') setNotice('当前服务不支持此操作。');
      else setNotice('设置无效，请检查输入。');
    } catch { if (alive.current && generation.current === id) setNotice('无法保存，请检查输入和连接。'); }
    finally { busyRef.current = false; if (alive.current && generation.current === id) setLoading(false); }
  };
  const loadVoices = async (next?: string) => {
    if (busyRef.current || provider !== 'elevenlabs') return;
    const id = ++generation.current; busyRef.current = true; setLoading(true); setNotice('');
    try {
      const result = await getClient().listElevenLabsVoices(next);
      if (alive.current && generation.current === id) { setVoices(old => next ? [...old, ...result.voices.filter(item => !old.some(previous => previous.id === item.id))] : result.voices); setCursor(result.nextCursor); }
    } catch (error) { if (alive.current && generation.current === id) setNotice(error instanceof Error && error.message === 'tts_unsupported' ? '当前服务不支持获取声音列表。' : '无法获取声音列表，请检查密钥和连接。'); }
    finally { busyRef.current = false; if (alive.current && generation.current === id) setLoading(false); }
  };
  return <View style={styles.section}>
    <Text style={[styles.heading, { color: ink }]}>语音输出</Text>
    <Text style={{ color: muted }}>此设置用于 CFL 之后生成的语音，其他客户端也会使用。</Text>
    {loading && <ActivityIndicator />}
    {!!notice && <Text accessibilityRole="alert" style={{ color: notice.includes('已保存') ? ink : dark ? '#ffb5ac' : '#9c302b' }}>{notice}</Text>}
    {!snapshot && !loading && <Button onPress={() => void load()}>刷新语音设置</Button>}
    {snapshot && <>
      <Text style={{ color: ink }}>语音服务</Text>
      <View style={styles.choices}>{providers.map(item => <Button key={item.id} variant={provider === item.id ? 'prominent' : 'soft'} disabled={loading || provider === item.id} onPress={() => changeProvider(item.id)}>{item.label}</Button>)}</View>
      {provider !== 'minimax' && <>
        <Text style={{ color: muted }}>{snapshot.configured[provider] ? '已配置密钥；保存新密钥会替换现有配置。' : '尚未配置密钥。'}</Text>
        <SecretInput value={apiKey} onChange={setApiKey} dark={dark} disabled={loading} />
        <Button disabled={loading || !apiKey} onPress={() => void save('key')}>保存密钥</Button>
      </>}
      <Text style={{ color: ink }}>声音 ID</Text>
      <Input accessibilityLabel="声音 ID" value={voice} onChangeText={setVoice} editable={!loading} autoCapitalize="none" autoCorrect={false} maxLength={512} placeholder="输入声音 ID" />
      {provider === 'elevenlabs' && <>
        <Text style={{ color: muted }}>获取声音列表会访问 ElevenLabs。</Text>
        <Button disabled={loading || !snapshot.configured.elevenlabs} onPress={() => void loadVoices()}>获取已保存的声音</Button>
        {voices.map(item => <Button key={item.id} variant={voice === item.id ? 'prominent' : 'soft'} disabled={loading || voice === item.id} onPress={() => setVoice(item.id)}>{item.name}</Button>)}
        {!!cursor && <Button disabled={loading} onPress={() => void loadVoices(cursor)}>加载更多声音</Button>}
      </>}
      {(provider === 'minimax' || provider === 'bytedance') && <><Text style={{ color: ink }}>语速（0.5–2，留空使用默认）</Text>
        <Input accessibilityLabel="语速" value={speed} onChangeText={setSpeed} editable={!loading} keyboardType="decimal-pad" placeholder="默认" /></>}
      <Button variant="prominent" disabled={loading || !voice.trim()} onPress={() => void save('settings')}>保存语音设置</Button>
    </>}
  </View>;
}
const styles = StyleSheet.create({ section: { gap: 12 }, heading: { fontSize: 16, fontWeight: '600' }, choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 } });
