import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Platform, ScrollView, StyleSheet, Text, View } from 'react-native';
import { BottomSheet, Host, RNHostView, Switch } from '@expo/ui';
import { MODEL_CHOICES, ModelSettingsClient, type ModelSelection, type ModelSettings } from '../cfl/model-settings';
import type { ChatController } from '../cfl/chat';
import type { ApiTransport } from '../cfl/transport';
import { BackgroundSettingsClient, type BackgroundKind, type BackgroundSnapshot } from '../cfl/background-settings';
import { pickImages, type AttachmentDraft } from '../cfl/drafts';
import { Button } from './Button';
import { VoiceSettings } from './VoiceSettings';
import { useAppearance } from './appearance';

export function ChatSettings({ controller, media, dark, onClose, onBackgroundSaved }: { controller: ChatController; media: ApiTransport; dark: boolean; onClose: () => void; onBackgroundSaved: () => void }) {
  const service = useMemo(() => new ModelSettingsClient(controller, media), [controller, media]);
  const [snapshot, setSnapshot] = useState<ModelSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [notice, setNotice] = useState('');
  const active = useRef(false), writing = useRef(false), generation = useRef(0);
  const background = useRef<BackgroundSettingsClient | null>(null), backgroundBusy = useRef(false);
  const [backgrounds, setBackgrounds] = useState<BackgroundSnapshot | null>(null);
  const [backgroundLoading, setBackgroundLoading] = useState(true);
  const [backgroundNotice, setBackgroundNotice] = useState('');
  const { colorMode, setColorMode } = useAppearance();
  const ink = dark ? '#f4f4f6' : '#252631';
  const muted = dark ? '#b6bcc6' : '#616975';
  const load = async () => {
    const id = ++generation.current; setLoading(true); setNotice('');
    try { const value = await service.load(); if (active.current && generation.current === id) setSnapshot(value); }
    catch { if (active.current && generation.current === id) { setSnapshot(null); setNotice('无法读取模型设置，请检查连接。'); } }
    finally { if (active.current && generation.current === id) setLoading(false); }
  };
  useEffect(() => { active.current = true; void load(); return () => { active.current = false; generation.current++; }; }, [service]);
  const loadBackgrounds = async (client: BackgroundSettingsClient) => {
    const originSession = controller.snapshot().view?.sessionId;
    setBackgroundLoading(true); setBackgroundNotice('');
    try { const value = await client.load(); if (client.current()) setBackgrounds(value); }
    catch { if (active.current && controller.snapshot().view?.sessionId === originSession) { setBackgrounds(null); setBackgroundNotice('无法读取背景设置，请检查连接。'); } }
    finally { if (active.current && controller.snapshot().view?.sessionId === originSession) setBackgroundLoading(false); }
  };
  const refreshBackgrounds = () => {
    let client = background.current;
    if (!client?.current()) {
      client?.dispose();
      try { client = new BackgroundSettingsClient(controller, media); background.current = client; }
      catch { setBackgroundNotice('无法读取背景设置，请检查连接。'); return; }
    }
    void loadBackgrounds(client);
  };
  useEffect(() => {
    let client: BackgroundSettingsClient;
    try { client = new BackgroundSettingsClient(controller, media); background.current = client; void loadBackgrounds(client); }
    catch { setBackgroundLoading(false); setBackgroundNotice('无法读取背景设置，请检查连接。'); return; }
    return () => { client.dispose(); background.current?.dispose(); background.current = null; };
  }, [controller, media]);
  const chooseBackground = async (kind: BackgroundKind) => {
    const client = background.current;
    if (!client || !client.current() || backgroundBusy.current) return;
    const originSession = controller.snapshot().view?.sessionId;
    backgroundBusy.current = true; setBackgroundLoading(true); setBackgroundNotice('');
    let drafts: AttachmentDraft[] | null = null;
    try {
      drafts = await pickImages(client.current);
      if (!drafts || !client.current()) return;
      if (drafts.length !== 1) { setBackgroundNotice('请选择一张图片作为背景。'); return; }
      const result = await client.save(kind, drafts[0]);
      if (!client.current()) {
        if (active.current && controller.snapshot().view?.sessionId === originSession && result.state === 'unknown') {
          setBackgrounds(null); setBackgroundNotice('保存结果未确认。刷新只能查看当前状态，不会自动重复上传。');
        }
        return;
      }
      if (result.state === 'saved') { setBackgrounds(result.snapshot); onBackgroundSaved(); }
      else if (result.state === 'unknown') { setBackgrounds(null); setBackgroundNotice('保存结果未确认。刷新只能查看当前状态，不会自动重复上传。'); }
      else if (result.state === 'background_settings_busy') setBackgroundNotice('背景正在更新，请稍后再试。');
      else if (result.state === 'background_too_large') setBackgroundNotice('背景图片不能超过 20 MiB。');
      else setBackgroundNotice('无法使用这张图片，请选择受支持的静态图片。');
    } catch (error) {
      if (client.current()) setBackgroundNotice(error instanceof Error && error.message === 'background_too_large' ? '背景图片不能超过 20 MiB。' : '无法使用这张图片，请选择受支持的静态图片。');
    } finally { drafts?.forEach(draft => draft.release()); backgroundBusy.current = false; if (active.current && controller.snapshot().view?.sessionId === originSession) setBackgroundLoading(false); }
  };
  const select = async (choice: ModelSelection) => {
    if (!snapshot || snapshot.busy || writing.current) return;
    const id = ++generation.current; writing.current = true; setLoading(true); setNotice('');
    try {
      const result = await service.select(snapshot, choice);
      if (!active.current || generation.current !== id) return;
      if (result.state === 'saved') setSnapshot(result.snapshot);
      else if (result.state === 'stale_model' || result.state === 'model_busy') {
        setSnapshot(result.snapshot); setNotice(result.state === 'model_busy' ? '聊天正在进行，请稍后再修改。' : '设置已变化，请检查当前设置。');
      } else {
        setSnapshot(null);
        setNotice(result.state === 'unknown' ? '修改结果未确认。刷新只能查看当前状态，不会自动重复提交。' : '无法修改模型设置，请检查连接和权限。');
      }
    } catch { if (active.current && generation.current === id) { setSnapshot(null); setNotice('设置已变化，请刷新后再选择。'); } }
    finally { writing.current = false; if (active.current && generation.current === id) setLoading(false); }
  };
  const selectedModel = MODEL_CHOICES.find(item => item.id === snapshot?.currentModel);
  return <BottomSheet isPresented onDismiss={onClose} snapPoints={['full']} containerColor={dark ? '#25282d' : '#f7f8fa'} testID="chat-settings-sheet">
    <RNHostView><View style={styles.page}>
      <View style={styles.heading}><Text style={[styles.title, { color: ink }]}>设置</Text><Button accessibilityLabel="关闭设置" variant="ghost" icon={{ ios: 'xmark', web: 'close', android: 'close' }} onPress={onClose} /></View>
      <ScrollView keyboardShouldPersistTaps="always" contentContainerStyle={styles.content}>
      <Text style={[styles.section, { color: ink }]}>外观</Text>
      <View style={styles.choices}>{([{ id: 'system', label: '跟随系统' }, { id: 'light', label: '浅色' }, { id: 'dark', label: '深色' }] as const).map(item =>
        <Button key={item.id} variant={colorMode === item.id ? 'prominent' : 'soft'} disabled={colorMode === item.id} onPress={() => setColorMode(item.id)}>{item.label}</Button>)}</View>
      <Text style={[styles.section, { color: ink }]}>模型</Text>
      {loading && <ActivityIndicator />}
      {!!notice && <Text accessibilityRole="alert" style={{ color: dark ? '#ffb5ac' : '#9c302b' }}>{notice}</Text>}
      {!snapshot && !loading && <Button onPress={() => void load()}>刷新设置</Button>}
      {snapshot && <>
        <Text style={{ color: muted }}>{snapshot.busy ? '聊天正在进行，暂时无法修改模型。' : `当前：${selectedModel?.name ?? snapshot.currentModel}`}</Text>
        <View style={styles.choices}>{MODEL_CHOICES.map(item => <Button key={item.id} variant={snapshot.currentModel === item.id ? 'prominent' : 'soft'} disabled={loading || snapshot.busy || snapshot.currentModel === item.id}
          onPress={() => void select({ model: item.id, fast: snapshot.fast })}>{item.name}</Button>)}</View>
        {Platform.OS === 'web' ? <Button variant="soft" disabled={loading || snapshot.busy || !selectedModel} onPress={() => { if (selectedModel) void select({ model: selectedModel.id, fast: !snapshot.fast }); }}>{`Fast 模式：${snapshot.fast ? '开' : '关'}`}</Button>
          : <Host matchContents ignoreSafeArea="all"><Switch label="Fast 模式" value={snapshot.fast} disabled={loading || snapshot.busy || !selectedModel} onValueChange={fast => { if (selectedModel) void select({ model: selectedModel.id, fast }); }} /></Host>}
      </>}
      <Text style={[styles.section, { color: ink }]}>聊天背景</Text>
      {backgroundLoading && <ActivityIndicator />}
      {!!backgroundNotice && <Text accessibilityRole="alert" style={{ color: dark ? '#ffb5ac' : '#9c302b' }}>{backgroundNotice}</Text>}
      {!backgrounds && !backgroundLoading && <Button onPress={refreshBackgrounds}>刷新背景设置</Button>}
      {backgrounds && <View style={styles.choices}>
        <Button accessibilityLabel="设置竖屏背景" disabled={backgroundLoading} onPress={() => void chooseBackground('portrait')}>{backgrounds.portrait ? '更换竖屏背景' : '设置竖屏背景'}</Button>
        <Button accessibilityLabel="设置横屏背景" disabled={backgroundLoading} onPress={() => void chooseBackground('landscape')}>{backgrounds.landscape ? '更换横屏背景' : '设置横屏背景'}</Button>
      </View>}
      <VoiceSettings controller={controller} media={media} dark={dark} />
      </ScrollView>
    </View></RNHostView>
  </BottomSheet>;
}
const styles = StyleSheet.create({ page: { flex: 1, paddingHorizontal: 16, paddingBottom: 16, gap: 14 }, content: { gap: 14 }, heading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, title: { fontSize: 19, fontWeight: '600' }, section: { fontSize: 16, fontWeight: '600' }, choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 } });
