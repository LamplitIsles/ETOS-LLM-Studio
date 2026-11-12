import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { renderInputArea } from '../modules/etos-input-area/src/slots';
import type { InputAreaProps } from '../modules/etos-input-area/src/index.ios';

const Host = () => null;
const Slot = () => null;
const InputArea = (props: InputAreaProps) => renderInputArea(Host, Slot, props);

test('input area retains ordered slots and remounts the host for a new generation', () => {
  const composer = React.createElement('composer');
  const panel = React.createElement('panel');
  const a = InputArea({ generation: 1, composer, panel });
  const b = InputArea({ generation: 2, composer, panel: null });
  const aAgain = InputArea({ generation: 3, composer, panel });
  assert.deepEqual([a.key, b.key, aAgain.key], ['1', '2', '3']);
  const slots = a.props.children;
  assert.equal(slots.length, 2);
  assert.deepEqual(slots.map((slot: React.ReactElement) => slot.key), ['composer', 'panel']);
  assert.equal(slots[0].props.collapsable, false);
  assert.equal(slots[1].props.collapsable, false);
  assert.equal(slots[0].props.children, composer);
  assert.equal(slots[1].props.children, panel);
  assert.equal(b.props.children.length, 2);
  assert.equal(b.props.children[1].props.children, null);
});
