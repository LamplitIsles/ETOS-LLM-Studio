// Real MessageText, with test-owned image loading and a minimal renderer.
const { build } = require('esbuild');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const mocks = {
    'react-native': `import React from 'react'; export const Text = ({children}) => <span>{children}</span>; export const Platform = {OS: 'ios'}; export const Linking = {openURL: async () => {}};`,
    'react-native-enriched-markdown': `import React, {useEffect} from 'react'; export function EnrichedMarkdownText({resolveImageSource, markdown}) { useEffect(() => { window.__resolver = resolveImageSource; }, [resolveImageSource]); return <span>{markdown}</span>; }`,
    '../cfl/markdown-resolver': `export const markdownImageResolverAvailable = () => true;`,
    '../cfl/markdown-image': `export const classifyMarkdownImage = () => ({kind: 'workspace'}); export const loadMarkdownImage = async (url, media, options) => { window.__signals = window.__signals || []; window.__signals.push(options.signal); if (url === 'delayed') return new Promise(resolve => { window.__finishOld = () => resolve({}); }); return {}; };`,
    '../cfl/markdown-image-uri': `export async function createMarkdownImageUri() { return {uri: 'fixture', release: () => { window.__released = (window.__released || 0) + 1; }}; }`,
  };
  const output = await build({
    entryPoints: ['tests/recycle-markdown-entry.jsx'], bundle: true, write: false, platform: 'browser', format: 'iife',
    plugins: [{ name: 'fixture-renderer', setup(builder) {
      builder.onResolve({ filter: /.*/ }, args => Object.hasOwn(mocks, args.path) ? { path: args.path, namespace: 'mock' } : null);
      builder.onLoad({ filter: /.*/, namespace: 'mock' }, args => ({ contents: mocks[args.path], loader: 'jsx', resolveDir: process.cwd() }));
    } }],
  });
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    await page.setContent('<div id="root"></div>');
    await page.addScriptTag({ content: output.outputFiles[0].text });
    await page.waitForFunction(() => typeof window.__resolver === 'function');
    await page.evaluate(async () => {
      window.__old = window.__resolver;
      await window.__old({ url: 'loaded' });
      window.__pending = window.__old({ url: 'delayed' });
    });
    await page.locator('#swap').click();
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const state = await page.evaluate(() => ({
      aborted: window.__signals[0].aborted,
      released: window.__released || 0,
      swapped: window.__resolver !== window.__old,
    }));
    assert.deepEqual(state, { aborted: true, released: 1, swapped: true });
    const delayed = await page.evaluate(async () => { window.__finishOld(); return await window.__pending; });
    assert.equal(delayed.uri, '');
    console.log('PASS: previous message image work is canceled, released and ignored');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
