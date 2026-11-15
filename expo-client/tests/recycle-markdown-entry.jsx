import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { MessageText } from '../src/ui/MessageText';

const controller = { scope: () => () => true };
const media = { origin: 'fixture://local' };
function Test() {
  const [messageId, setMessageId] = useState('a');
  return <>
    <button id="swap" onClick={() => setMessageId('b')}>swap</button>
    <MessageText messageId={messageId} text={messageId} foreground="#fff" dark
      media={media} controller={controller} workspaceImages />
  </>;
}
createRoot(document.getElementById('root')).render(<Test />);
