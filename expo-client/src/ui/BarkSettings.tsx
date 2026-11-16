import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Platform, StyleSheet, Text, View } from 'react-native';
import { Host, Switch } from '@expo/ui';
import { Button } from './Button';
import { SecretInput } from './SecretInput';
import type { BarkAction, BarkResult, BarkSnapshot, BarkTestResult } from '../cfl/bark-settings';

type BarkClient = {
  current(): boolean;
  load(): Promise<BarkSnapshot>;
  update(action: BarkAction): Promise<BarkResult>;
  testNotification(): Promise<BarkTestResult>;
  dispose(): void;
};

export function BarkSettings({ createClient, dark }: { createClient: () => BarkClient; dark: boolean }) {
  const alive = useRef(false), generation = useRef(0), busy = useRef<symbol | null>(null);
  const clientRef = useRef<BarkClient | null>(null);
  const [snapshot, setSnapshot] = useState<BarkSnapshot | null>(null);
  const [key, setKey] = useState(''), [loading, setLoading] = useState(true), [notice, setNotice] = useState('');
  const ink = dark ? '#f4f4f6' : '#252631', muted = dark ? '#b6bcc6' : '#616975';
  const load = async () => {
    if (busy.current) return;
    const id = ++generation.current; setLoading(true); setNotice('');
    try {
      let client = clientRef.current;
      if (!client || !client.current()) { client?.dispose(); client = createClient(); clientRef.current = client; }
      const next = await client.load();
      if (alive.current && client.current() && id === generation.current) setSnapshot(next);
    } catch (error) {
      if (alive.current && id === generation.current) {
        setSnapshot(null); setNotice(error instanceof Error && error.message === 'unsupported' ? '当前服务不支持 Bark。' : '无法读取 Bark 设置。');
      }
    } finally { if (alive.current && id === generation.current) setLoading(false); }
  };
  useEffect(() => {
    alive.current = true; void load();
    return () => { alive.current = false; generation.current++; busy.current = null; clientRef.current?.dispose(); clientRef.current = null; };
  }, [createClient]);
  const update = async (action: BarkAction) => {
    const client = clientRef.current;
    if (!client) return;
    if (busy.current || !snapshot || !client.current()) return;
    if (action.action === 'set') setKey('');
    const id = ++generation.current, operation = Symbol('bark-settings'); busy.current = operation; setLoading(true); setNotice('');
    try {
      const result = await client.update(action);
      if (!alive.current || id !== generation.current) return;
      if (result.state === 'unknown') { setSnapshot(null); setNotice(action.action === 'set' ? '保存结果未确认。刷新只能查看是否已配置，不能确认此次 key 是否生效。' : '保存结果未确认，请刷新设置。'); return; }
      if (!client.current()) { setSnapshot(null); setNotice('连接已中断，请刷新设置。'); return; }
      if (result.state === 'saved') setSnapshot(result.snapshot);
      else {
        if (result.state === 'invalid' && action.action === 'set') setKey(action.key);
        setNotice(result.state === 'unsupported' ? '当前服务不支持 Bark。' : result.state === 'access_denied' ? '登录已失效。' : result.state === 'invalid' ? '请检查 Bark key。' : '设置正在更新，请稍后再试。');
      }
    } catch { if (alive.current && id === generation.current) { setSnapshot(null); setNotice(action.action === 'set' ? '保存结果未确认。刷新只能查看是否已配置，不能确认此次 key 是否生效。' : '保存结果未确认，请刷新设置。'); } }
    finally { if (busy.current === operation) busy.current = null; if (alive.current && id === generation.current) setLoading(false); }
  };
  const sendTest = async () => {
    const client = clientRef.current;
    if (!client || !client.current() || !snapshot?.configured || !snapshot.enabled || busy.current) return;
    const id = ++generation.current, operation = Symbol('bark-test'); busy.current = operation; setLoading(true); setNotice('');
    try {
      const result = await client.testNotification();
      if (!alive.current || id !== generation.current) return;
      const messages: Record<BarkTestResult['state'], string> = {
        accepted: '测试请求已提交，请查看 Bark 通知。',
        bark_not_configured: '尚未配置 Bark key，请刷新设置。',
        bark_disabled: '通知已关闭，请刷新设置后开启。',
        bark_upstream_rejected: 'Bark 服务拒绝了测试请求，请检查配置。',
        unsupported: '当前服务不支持测试通知。',
        busy: '设置正在更新，请稍后再试。',
        unknown: '发送结果未确认，通知可能已送达，请先查看 Bark。',
      };
      if (result.state === 'bark_not_configured' || result.state === 'bark_disabled') setSnapshot(null);
      setNotice(result.state === 'accepted' && !client.current() ? messages.unknown : messages[result.state]);
    } catch {
      if (alive.current && id === generation.current) setNotice('发送结果未确认，通知可能已送达，请先查看 Bark。');
    } finally {
      if (busy.current === operation) busy.current = null;
      if (alive.current && id === generation.current) setLoading(false);
    }
  };
  return <View style={styles.section}>
    <Text style={[styles.heading, { color: ink }]}>Bark 通知</Text>
    {loading && <ActivityIndicator />}
    {!!notice && <Text accessibilityRole="alert" style={{ color: dark ? '#ffb5ac' : '#9c302b' }}>{notice}</Text>}
    {!snapshot && !loading && <Button onPress={() => void load()}>刷新通知设置</Button>}
    {snapshot && <>
      <Text style={{ color: muted }}>{snapshot.configured ? '已配置 Bark key' : '尚未配置 Bark key'}</Text>
      <SecretInput value={key} onChange={setKey} dark={dark} disabled={loading} label="Bark key" placeholder="输入 Bark key" />
      <Button disabled={loading || !key} onPress={() => void update({ action: 'set', key })}>保存</Button>
      {Platform.OS === 'web' ? <Button variant="soft" disabled={loading || !snapshot.configured} onPress={() => void update({ action: snapshot.enabled ? 'disable' : 'enable' })}>{`通知：${snapshot.enabled ? '开' : '关'}`}</Button>
        : <Host matchContents ignoreSafeArea="all"><Switch label="通知" value={snapshot.enabled} disabled={loading || !snapshot.configured} onValueChange={enabled => { void update({ action: enabled ? 'enable' : 'disable' }); }} /></Host>}
      <Button variant="soft" disabled={loading || !snapshot.configured || !snapshot.enabled} onPress={() => void sendTest()}>发送测试通知</Button>
      {snapshot.configured && <Button variant="ghost" disabled={loading} onPress={() => void update({ action: 'remove' })}>删除 Bark key</Button>}
    </>}
  </View>;
}

const styles = StyleSheet.create({ section: { gap: 12 }, heading: { fontSize: 16, fontWeight: '600' } });
