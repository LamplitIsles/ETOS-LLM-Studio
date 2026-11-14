// Test-owned real Chromium pixel decoding; does not start a server or access accounts.
const { chromium } = require('@playwright/test');
const { build } = require('esbuild');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const bundle = await build({ entryPoints: [join(__dirname, '../src/cfl/sticker-opacity.ts')], bundle: true, platform: 'browser', format: 'iife', globalName: 'OpacityTest', write: false });
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  try {
    const page = await browser.newPage();
    let requests = 0; page.on('request', () => { requests++; });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const cases = [
      ['rgb.png', 'image/png', 'opaque'], ['rgba-opaque.png', 'image/png', 'opaque'],
      ['rgba-transparent.png', 'image/png', 'transparent'], ['opaque.jpg', 'image/jpeg', 'opaque'],
      ['opaque.webp', 'image/webp', 'opaque'], ['transparent.webp', 'image/webp', 'transparent'],
      ['animated.gif', 'image/gif', 'unknown'], ['animated.webp', 'image/webp', 'unknown'],
      ['animated.png', 'image/png', 'unknown'], ['rgba16.png', 'image/png', 'unknown'],
    ];
    for (const [file, contentType, expected] of cases) {
      const base64 = readFileSync(join(__dirname, 'fixtures/opacity', file)).toString('base64');
      const got = await page.evaluate(async ({ base64, contentType }) => {
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        return OpacityTest.classifyStickerOpacity({ bytes, contentType }, () => true);
      }, { base64, contentType });
      assert.equal(got, expected, file);
    }
    const corrupt = readFileSync(join(__dirname, 'fixtures/opacity/rgb.png'));
    const idat = corrupt.indexOf(Buffer.from('IDAT')); assert.ok(idat > 0); corrupt[idat + 5] ^= 0xff;
    const malformed = await page.evaluate(async base64 => {
      const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      return OpacityTest.classifyStickerOpacity({ bytes, contentType: 'image/png' }, () => true);
    }, corrupt.toString('base64'));
    assert.equal(malformed, 'unknown'); assert.equal(requests, 0);
    console.log(`classifier: ${cases.length} real Chromium image cases plus corrupt decode passed; no requests`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
