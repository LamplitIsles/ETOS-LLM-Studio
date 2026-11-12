import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

test('source limits stacking changes to the owned mounted child without replacing UIKit hitTest', () => {
  const panel = readFileSync(new URL('../modules/etos-input-area/ios/ETOSKeyboardPanelView.swift', import.meta.url), 'utf8');
  assert.match(panel, /private weak var ownedChild: UIView\?/);
  assert.match(panel, /child\.superview === self, child\.window === currentWindow/);
  assert.match(panel, /bringSubviewToFront\(child\)/);
  assert.match(panel, /super\.didMoveToWindow\(\)\s+promoteOwnedChild\(\)/);
  assert.match(panel, /mountedChildren\.count == 1 \? childComponentView : nil/);
  assert.match(panel, /aboveSubview: mountedChildren\[index - 1\]/);
  assert.match(panel, /belowSubview: mountedChildren\[1\]/);
  assert.match(panel, /trackOwnedChild\(nil, promote: false\)/);
  assert.doesNotMatch(panel, /inputSurface\.insertSubview\(childComponentView, at: index\)/);
  assert.doesNotMatch(panel, /override func hitTest/);
});
