// Temporary patch for the exact MIT-licensed nightly in package-lock.json.
// Validate every input before writing anything; an upstream change must be reviewed.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'node_modules', 'react-native-enriched-markdown');
const version = '1.2.0-nightly-20261109-ca015bcac';
const webBefore = "    width: size,\n    height: size,\n    verticalAlign: 'middle',";
const webAfter = "    width: size,\n    height: size,\n    objectFit: 'contain',\n    borderRadius: style.image.borderRadius,\n    verticalAlign: 'middle',";
const iosBefore = `    } else {
      drawingWidth = targetWidth;
      drawingHeight = targetHeight;
    }
    drawingRect = CGRectMake`;
const iosAfter = `    } else {
      CGFloat aspectRatioScale = MIN(targetWidth / sourceWidth, targetHeight / sourceHeight);
      drawingWidth = sourceWidth * aspectRatioScale;
      drawingHeight = sourceHeight * aspectRatioScale;
    }
    drawingRect = CGRectMake`;
const files = [
  ['src/web/styles.ts', '082f414358d06d6442cd1eae48934c62b4b8b89ccd4aad3d39bfe9c3b846e8b4', 'caa984c507a3aebfd9c78a5348c6847d3df15e5a9366fca390d8b9494f92f1a8', webBefore, webAfter],
  ['lib/module/web/styles.js', '91763dfa9bdb34751bc2343d48be8467af2b4b3c8a98e5209334a1e8bbecbce1', '45db409f24302cb7990565a74615a916db5fcb5e18888ea5c95881b20a9042fa', webBefore, webAfter],
  ['ios/attachments/ENRMImageAttachment.m', 'ae003b84a78682019ddab7324a20c33e0c84f9ffa10d1cbf8fc2b7cc5b692bc5', '2e20387999225e8816f9976c7a7dddac8ebffe30e0bd9202ee99005ff083a785', iosBefore, iosAfter],
];
const hash = (value) => createHash('sha256').update(value).digest('hex');

try {
  const installed = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  if (installed.version !== version) throw new Error(`expected ${version}, found ${installed.version}`);
  const changes = files.map(([name, originalHash, patchedHash, before, after]) => {
    const path = join(root, name);
    const input = readFileSync(path, 'utf8');
    if (hash(input) === patchedHash) return null;
    if (hash(input) !== originalHash || input.split(before).length !== 2) {
      throw new Error(`${name} does not match the pinned upstream source or the applied patch`);
    }
    const output = input.replace(before, after);
    if (hash(output) !== patchedHash) throw new Error(`${name} patch verification failed`);
    return { path, output };
  });
  for (const change of changes) if (change) writeFileSync(change.path, change.output);
  console.log('Verified enriched-markdown inline image patch.');
} catch (error) {
  console.error('Cannot apply enriched-markdown inline image patch:', error.message);
  process.exitCode = 1;
}
