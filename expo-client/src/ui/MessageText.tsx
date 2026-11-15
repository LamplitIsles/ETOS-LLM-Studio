import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Linking, Platform, Text } from 'react-native';
import { EnrichedMarkdownText, type MarkdownStyle } from 'react-native-enriched-markdown';
import type { ApiTransport } from '../cfl/transport';
import type { ChatController } from '../cfl/chat';
import { classifyMarkdownImage, loadMarkdownImage } from '../cfl/markdown-image';
import { createMarkdownImageUri } from '../cfl/markdown-image-uri';
import { markdownImageResolverAvailable } from '../cfl/markdown-resolver';

const fallbackStyle = { fontSize: 16, lineHeight: 23 };

// An older native build without the parser cannot intercept embedded media.
const embeddedMedia = /!\[|<\s*\/?\s*(?:img|video|source|audio|iframe)\b/i;

export function MessageText({ text, foreground, dark, media, controller, workspaceImages, messageId }: {
  text: string; foreground: string; dark: boolean; media: ApiTransport; controller: ChatController; workspaceImages: boolean; messageId?: string;
}) {
  const [resolver, setResolver] = useState<null | { messageId?: string; resolve: (image: { url: string }) => Promise<{ uri: string }> }>(null);
  const resolveImage = resolver?.messageId === messageId ? resolver?.resolve : null;
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
    setResolver({ messageId, resolve });
    return () => { active = false; abort.abort(); for (const release of releases) release(); };
  }, [controller, media, workspaceImages, resolverAvailable, messageId]);
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
  if (!resolverAvailable && embeddedMedia.test(text)) return <Text selectable style={[fallbackStyle, { color: foreground }]}>{text}</Text>;
  if (resolverAvailable && !resolveImage) return null;
  return <EnrichedMarkdownText markdown={text} flavor="github" markdownStyle={markdownStyle}
    md4cFlags={{ hardSoftBreaks: true }} selectable enableTaskListItemToggle={false}
    enableLinkPreview={false} onLinkPress={openLink}
    {...(resolveImage ? { resolveImageSource: resolveImage, renderers: { video: () => <Text style={{ color: foreground }}>视频暂不支持显示</Text> } } : {})} />;
}
