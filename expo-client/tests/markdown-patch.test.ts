import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const files = ['src/web/styles.ts', 'lib/module/web/styles.js', 'ios/attachments/ENRMImageAttachment.m'];
const webPatch = "    objectFit: 'contain',\n    borderRadius: style.image.borderRadius,\n";
const iosPatch = `      CGFloat aspectRatioScale = MIN(targetWidth / sourceWidth, targetHeight / sourceHeight);
      drawingWidth = sourceWidth * aspectRatioScale;
      drawingHeight = sourceHeight * aspectRatioScale;`;
const iosOriginal = `      drawingWidth = targetWidth;
      drawingHeight = targetHeight;`;

test('nightly patch applies, is repeatable, and rejects drift before writing', () => {
  const tmp = mkdtempSync(join(tmpdir(), 'etos-markdown-patch-'));
  try {
    const script = join(tmp, 'scripts/patch-enriched-markdown.mjs');
    const root = join(tmp, 'node_modules/react-native-enriched-markdown');
    mkdirSync(dirname(script), { recursive: true });
    copyFileSync('scripts/patch-enriched-markdown.mjs', script);
    mkdirSync(root, { recursive: true });
    const packageFile = join(root, 'package.json');
    writeFileSync(packageFile, JSON.stringify({ version: '1.2.0-nightly-20261109-ca015bcac' }));
    for (const name of files) {
      const target = join(root, name);
      mkdirSync(dirname(target), { recursive: true });
      const input = readFileSync(join('node_modules/react-native-enriched-markdown', name), 'utf8');
      // Permit running this test before or after the project postinstall.
      writeFileSync(target, input.replace(webPatch, '').replace(iosPatch, iosOriginal));
    }
    const run = () => spawnSync(process.execPath, [script], { encoding: 'utf8' });
    assert.equal(run().status, 0);
    for (const name of files.slice(0, 2)) {
      const source = readFileSync(join(root, name), 'utf8');
      assert.match(source, /objectFit: 'contain'/);
      assert.match(source, /borderRadius: style\.image\.borderRadius/);
    }
    assert.match(readFileSync(join(root, files[2]), 'utf8'), /MIN\(targetWidth \/ sourceWidth, targetHeight \/ sourceHeight\)/);
    assert.equal(run().status, 0);
    writeFileSync(packageFile, JSON.stringify({ version: 'different' }));
    assert.notEqual(run().status, 0);
    writeFileSync(packageFile, JSON.stringify({ version: '1.2.0-nightly-20261109-ca015bcac' }));
    const first = join(root, files[0]);
    const pristine = readFileSync(first, 'utf8').replace(webPatch, '');
    writeFileSync(first, pristine);
    writeFileSync(join(root, files[2]), 'unexpected upstream modification');
    assert.notEqual(run().status, 0);
    assert.equal(readFileSync(first, 'utf8'), pristine, 'all files are checked before any write');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
